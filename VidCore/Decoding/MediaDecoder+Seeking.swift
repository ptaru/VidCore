//
//  MediaDecoder+Seeking.swift
//  VidCore
//

import CoreMedia
import Foundation

extension MediaDecoder {
    
    // Helper function to consolidate VideoFrame creation
    @inline(__always)
    func createVideoFrame(
        sampleBuffer: CMSampleBuffer? = nil,
        pixelBuffer: CVPixelBuffer? = nil,
        presentationTime: Double,
        doviProfile: Int = 0,
        ambientLightMetadata: Data? = nil
    ) -> VideoFrame? {
        // Cache properties to avoid repeated access if called in loop
        if let sampleBuffer = sampleBuffer {
            return VideoFrame(
                sampleBuffer: sampleBuffer,
                presentationTime: presentationTime,
                isHDR: self.videoInfo.isHDR,
                colorTransfer: Int(self.videoInfo.colorTransfer),
                doviProfile: self.videoInfo.isDolbyVision ? Int(self.videoInfo.doviProfile ?? 0) : 0,
                ambientLightMetadata: ambientLightMetadata
            )
        } else if let pixelBuffer = pixelBuffer {
            return self.makeVideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                doviProfile: doviProfile,
                ambientLightMetadata: ambientLightMetadata
            )
        }
        return nil
    }

    /// Asynchronously seeks to a specific time in the video.
    ///
    /// This method handles both normal FFmpeg decoding and hardware passthrough seeking.
    /// It flushes internal buffers and prepares the decoder for the new timeline.
    ///
    /// - Parameter seconds: The target time in seconds.
    /// - Returns: The first `VideoFrame` at or after the seek target, or `nil` if seeking fails or no frame is found.
    /// - Throws: An error if the seek operation fails (e.g., invalid time, I/O error).
    public func seek(to seconds: Double) async throws -> VideoFrame?
    {
        // Acquire lock to check state
        if checkIsClosed() { return nil }
        let clampedSeconds = max(0, seconds)
        var didRequestAbortIO = false

        func checkCancellationAndAbortDemuxIfNeeded() async throws {
            if Task.isCancelled {
                await demuxerActor.requestAbortIO()
                didRequestAbortIO = true
                throw CancellationError()
            }
        }

        // 1. Eliminate Redundant Lock Operations: Combine state changes
        performUnderLock {
            self.isSeeking = true
            self.pendingContextRestorationPackets.removeAll()
            self.pendingContextRestorationIndex = 0
            self.pendingPassthroughCarryoverPackets.removeAll()
            self.pendingPassthroughCarryoverIndex = 0
        }

        // Defer reset of seek state
        defer {
            performUnderLock {
                self.isSeeking = false
            }
        }

        do {
            // 8. Reduce Task Cancellation Checks (Keep essential ones)
            try await checkCancellationAndAbortDemuxIfNeeded()

            // 2. Parallel Flush and Seek Operations
            // Run flush and seek in parallel to reduce latency
            async let flushTask: Void? = self.decoderActor?.flushCodecBuffers()
            async let seekTask = demuxerActor.seek(toKeyframe: clampedSeconds)

            _ = await flushTask
            let seekSuccess = await seekTask

            guard seekSuccess else {
                throw NSError(
                    domain: "MediaDecoder", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Seek failed - demux seek error"])
            }

            try await checkCancellationAndAbortDemuxIfNeeded()

            // 10. Cache VideoInfo Properties
            let isPassThrough = self.hardwareDecodeMode == .passThrough
        
            // 5. Unified Processing

            // Case A: Hardware Passthrough
            if isPassThrough, let builder = self.sampleBufferBuilder {
                // Passthrough requires GOP/context packets for AVSampleBufferDisplayLayer stability.
                guard let packets = await demuxerActor.collectPackets(until: clampedSeconds), !packets.isEmpty
                else {
                    return nil
                }
                // Use filter instead of loop to avoid intermediate array resizing.
                let restorationPackets = packets.filter { $0.isVideo || $0.isAudio }

                let maxForwardReads = 1200
                var demuxOrderedReadAheadPackets: [FFmpegDemuxerPacket] = []

                func readNextKeyframe(
                    maxReads: Int,
                    captureNonVideoPackets: inout [FFmpegDemuxerPacket]
                ) async throws -> FFmpegDemuxerPacket? {
                    var reads = 0
                    while reads < maxReads {
                        try await checkCancellationAndAbortDemuxIfNeeded()
                        guard let packet = await demuxerActor.demuxNextPacket() else {
                            return nil
                        }
                        reads += 1
                        if !packet.isVideo {
                            captureNonVideoPackets.append(packet)
                        }
                        if packet.isVideo && packet.isKeyframe {
                            return packet
                        }
                    }
                    return nil
                }

                func packetPTSSeconds(_ packet: FFmpegDemuxerPacket, multiplier: Double) -> Double? {
                    guard packet.pts != Int64.min else { return nil }
                    return Double(packet.pts) * multiplier
                }

                var videoPackets = restorationPackets.filter { $0.isVideo }

                // After a seek reset, leading non-key packets are unsafe decode anchors.
                if let firstKeyframeIndex = videoPackets.firstIndex(where: { $0.isKeyframe }),
                    firstKeyframeIndex > 0
                {
                    videoPackets.removeFirst(firstKeyframeIndex)
                }

                guard builder.timeBaseDen != 0 else {
                    throw NSError(
                        domain: "MediaDecoder", code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid timebase"])
                }
                let ptsMultiplier = Double(builder.timeBaseNum) / Double(builder.timeBaseDen)
                let targetTime = max(0, clampedSeconds - 0.05)
                var prerollPackets: [FFmpegDemuxerPacket] = []
                var passthroughCarryoverPackets: [FFmpegDemuxerPacket] = []
                let displayPacket: FFmpegDemuxerPacket
                let initialVideoPacketCount = videoPackets.count

                if videoPackets.isEmpty {
                    guard let keyframe = try await readNextKeyframe(
                        maxReads: maxForwardReads,
                        captureNonVideoPackets: &demuxOrderedReadAheadPackets
                    ) else {
                        return nil
                    }
                    displayPacket = keyframe
                } else {
                    var reachedTarget = videoPackets.contains {
                        if let ptsSeconds = packetPTSSeconds($0, multiplier: ptsMultiplier) {
                            return ptsSeconds >= targetTime
                        }
                        return false
                    }
                    var captureReadAheadPackets = reachedTarget

                    // If not found in initial collection, continue reading until we reach target.
                    while !reachedTarget {
                        try await checkCancellationAndAbortDemuxIfNeeded()
                        guard let nextPacket = await demuxerActor.demuxNextPacket() else {
                            break
                        }
                        guard nextPacket.isVideo else {
                            if captureReadAheadPackets {
                                demuxOrderedReadAheadPackets.append(nextPacket)
                            }
                            continue
                        }

                        // If we still have no decode anchor, wait for the first keyframe.
                        if videoPackets.isEmpty && !nextPacket.isKeyframe {
                            continue
                        }

                        videoPackets.append(nextPacket)
                        if captureReadAheadPackets {
                            demuxOrderedReadAheadPackets.append(nextPacket)
                        }

                        if let ptsSeconds = packetPTSSeconds(nextPacket, multiplier: ptsMultiplier),
                            ptsSeconds >= targetTime
                        {
                            reachedTarget = true
                            captureReadAheadPackets = true
                            if !demuxOrderedReadAheadPackets.isEmpty
                                && demuxOrderedReadAheadPackets.last === nextPacket
                            {
                                // Already captured above.
                            } else {
                                demuxOrderedReadAheadPackets.append(nextPacket)
                            }
                        }
                    }

                    // Extend to the next keyframe so we can choose display frame in presentation
                    // order and preserve the remaining decode-order packets.
                    let hasKeyframeAtOrAfterTarget = videoPackets.contains { packet in
                        guard packet.isKeyframe,
                            let ptsSeconds = packetPTSSeconds(packet, multiplier: ptsMultiplier)
                        else {
                            return false
                        }
                        return ptsSeconds >= targetTime
                    }
                    var nextGOPStartIndex = videoPackets.dropFirst().firstIndex(where: { $0.isKeyframe })
                    var forwardReads = 0
                    if !hasKeyframeAtOrAfterTarget {
                        while nextGOPStartIndex == nil && forwardReads < maxForwardReads {
                            try await checkCancellationAndAbortDemuxIfNeeded()
                            guard let nextPacket = await demuxerActor.demuxNextPacket() else {
                                break
                            }
                            demuxOrderedReadAheadPackets.append(nextPacket)

                            guard nextPacket.isVideo else {
                                continue
                            }

                            forwardReads += 1
                            videoPackets.append(nextPacket)
                            if nextPacket.isKeyframe {
                                nextGOPStartIndex = videoPackets.indices.last
                                break
                            }
                        }
                    }

                    let currentGOPEndIndex = nextGOPStartIndex ?? videoPackets.endIndex
                    let currentGOPPackets = Array(videoPackets[..<currentGOPEndIndex])
                    guard !currentGOPPackets.isEmpty else {
                        return nil
                    }

                    // Pick first frame at/after target in presentation order, not decode order.
                    let displayIndex: Int? = currentGOPPackets
                        .enumerated()
                        .compactMap { index, packet -> (Int, Double)? in
                            guard let ptsSeconds = packetPTSSeconds(packet, multiplier: ptsMultiplier),
                                ptsSeconds >= targetTime
                            else {
                                return nil
                            }
                            return (index, ptsSeconds)
                        }
                        .min { lhs, rhs in
                            if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
                            return lhs.1 < rhs.1
                        }?
                        .0

                    var candidateDisplayPacket: FFmpegDemuxerPacket
                    if let displayIndex {
                        prerollPackets = Array(currentGOPPackets.prefix(displayIndex))
                        candidateDisplayPacket = currentGOPPackets[displayIndex]
                    } else if let nextGOPStartIndex {
                        // Target fell after this GOP; display the next GOP keyframe.
                        prerollPackets = currentGOPPackets
                        candidateDisplayPacket = videoPackets[nextGOPStartIndex]
                    } else {
                        return nil
                    }

                    // Unsafe landing: reset + visible non-key with no preroll context.
                    if prerollPackets.isEmpty && !candidateDisplayPacket.isKeyframe {
                        guard let keyframe = try await readNextKeyframe(
                            maxReads: maxForwardReads,
                            captureNonVideoPackets: &demuxOrderedReadAheadPackets
                        ) else {
                            return nil
                        }
                        passthroughCarryoverPackets.removeAll()
                        candidateDisplayPacket = keyframe
                    }

                    displayPacket = candidateDisplayPacket

                    var skipIDs = Set<ObjectIdentifier>()
                    prerollPackets.forEach { skipIDs.insert(ObjectIdentifier($0)) }
                    skipIDs.insert(ObjectIdentifier(displayPacket))

                    // Keep initial post-seek packets in their original order first.
                    for packet in videoPackets.prefix(initialVideoPacketCount) {
                        let packetID = ObjectIdentifier(packet)
                        if !skipIDs.contains(packetID) {
                            passthroughCarryoverPackets.append(packet)
                            skipIDs.insert(packetID)
                        }
                    }

                    // Then append read-ahead packets in exact demux order to preserve A/V ordering.
                    for packet in demuxOrderedReadAheadPackets {
                        let packetID = ObjectIdentifier(packet)
                        if !skipIDs.contains(packetID) {
                            passthroughCarryoverPackets.append(packet)
                            skipIDs.insert(packetID)
                        }
                    }
                }

                // Store packets for context restoration and post-seek continuity.
                performUnderLock {
                    self.pendingContextRestorationPackets = prerollPackets
                    self.pendingContextRestorationIndex = 0
                    self.pendingPassthroughCarryoverPackets = passthroughCarryoverPackets
                    self.pendingPassthroughCarryoverIndex = 0
                }

                // Create the frame immediately.
                let sampleBuffer = try builder.createSampleBuffer(
                    from: displayPacket,
                    pts: displayPacket.pts,
                    dts: displayPacket.dts,
                    duration: displayPacket.duration,
                    forPassthrough: true,
                    ambientLightMetadata: displayPacket.ambientLightMetadata,
                    isKeyframe: displayPacket.isKeyframe,
                    resetDecoderBeforeDecoding: prerollPackets.isEmpty && displayPacket.isKeyframe
                )
            
                return createVideoFrame(
                    sampleBuffer: sampleBuffer,
                    presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
                    ambientLightMetadata: displayPacket.ambientLightMetadata
                )
            }
            // Case B: FFmpeg / Software Decoding
            else if let decoderActor = self.decoderActor {
                // FFmpeg software seek decodes packets in a streaming loop to avoid GOP buffering.
                let targetTime = max(0, clampedSeconds - 0.05)
                let maxVideoPacketsAfterSeek = 240
                let maxWallClockReads = 1200
                var videoPacketsRead = 0
                var totalReads = 0
                var foundFrame: VideoFrame? = nil

                await decoderActor.setFastSeekDecodingEnabled(true)
                do {
                    while foundFrame == nil
                        && videoPacketsRead < maxVideoPacketsAfterSeek
                        && totalReads < maxWallClockReads
                    {
                        try await checkCancellationAndAbortDemuxIfNeeded()
                        guard let packet = await demuxerActor.demuxNextPacket() else {
                            break  // EOF
                        }

                        totalReads += 1

                        if packet.isVideo {
                            videoPacketsRead += 1
                            if let frames = await decoderActor.decodeVideoPacket(
                                withAllFrames: packet)
                            {
                                if let f = frames
                                    .filter({ $0.presentationTime >= targetTime })
                                    .min(by: { $0.presentationTime < $1.presentationTime })
                                {
                                    foundFrame = self.createVideoFrame(
                                        pixelBuffer: f.pixelBuffer,
                                        presentationTime: f.presentationTime,
                                        doviProfile: Int(f.doviProfile),
                                        ambientLightMetadata: f.ambientLightMetadata
                                    )
                                }
                            }
                        } else if packet.isAudio {
                            _ = await decoderActor.decodeAudioPacket(withAllFrames: packet)
                        }
                    }

                    await decoderActor.setFastSeekDecodingEnabled(false)
                } catch {
                    await decoderActor.setFastSeekDecodingEnabled(false)
                    throw error
                }

                // Clear restoration packets as they are already decoded.
                performUnderLock {
                    self.pendingContextRestorationPackets.removeAll()
                    self.pendingContextRestorationIndex = 0
                    self.pendingPassthroughCarryoverPackets.removeAll()
                    self.pendingPassthroughCarryoverIndex = 0
                }

                return foundFrame
            }
        } catch {
            if didRequestAbortIO {
                await demuxerActor.clearAbortIO()
            }
            throw error
        }

        return nil
    }
}
