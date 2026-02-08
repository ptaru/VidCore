//
//  MediaDecoder+Seeking.swift
//  VidCore
//

import CoreMedia
import Foundation

extension MediaDecoder {
    /// Asynchronously seeks to a specific time in the video.
    ///
    /// This method handles both normal FFmpeg decoding and hardware passthrough seeking.
    /// It flushes internal buffers and prepares the decoder for the new timeline.
    ///
    /// - Parameter seconds: The target time in seconds.
    /// - Returns: The first `VideoFrame` at or after the seek target, or `nil` if seeking fails or no frame is found.
    /// - Throws: An error if the seek operation fails (e.g., invalid time, I/O error).
    public func seek(to seconds: Double, previewHandler: ((VideoFrame) -> Void)? = nil) async throws
        -> VideoFrame?
    {
        // Acquire lock to check state
        if checkIsClosed() { return nil }

        // Set seeking state to block regular demuxing
        performUnderLock {
            self.isSeeking = true
            self.pendingContextRestorationPackets.removeAll()
        }

        // Defer reset of seek state
        defer {
            performUnderLock {
                self.isSeeking = false
            }
        }

        try Task.checkCancellation()

        // 1. Flush Decoders
        if let decoderActor = self.decoderActor {
            await decoderActor.flushCodecBuffers()
        }

        try Task.checkCancellation()

        // 2. Perform Demuxer Seek
        let seekSuccess = await demuxerActor.seek(toKeyframe: seconds)
        guard seekSuccess else {
            throw NSError(
                domain: "MediaDecoder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Seek failed - demux seek error"])
        }

        try Task.checkCancellation()

        // 3. Preroll: Consume packets from Keyframe to Target
        // Collects packets to rebuild decoder context (GOP) up to the seek time.
        guard let packets = await demuxerActor.collectPackets(until: seconds), !packets.isEmpty
        else {
            return nil
        }

        // 4. Filter Packets
        var restorationPackets: [FFmpegDemuxerPacket] = []

        for packet in packets {
            if packet.isAudio {
                // Drop audio packets during preroll to prevent mixed-mode sync issues.
                continue
            } else {
                restorationPackets.append(packet)
            }
        }

        try Task.checkCancellation()

        // 5. Unified Processing

        // Case A: Hardware Passthrough
        if self.hardwareDecodeMode == .passThrough, let builder = self.sampleBufferBuilder {
            // PREVIEW: Try to show the first frame (keyframe) immediately
            if let previewHandler, let firstPacket = restorationPackets.first(where: { $0.isVideo })
            {
                try? Task.checkCancellation()
                if let previewSampleBuffer = try? builder.createSampleBuffer(
                    from: firstPacket.data,
                    pts: firstPacket.pts,
                    dts: firstPacket.dts,
                    duration: firstPacket.duration,
                    forPassthrough: true,
                    ambientLightMetadata: firstPacket.ambientLightMetadata
                ) {
                    let previewFrame = VideoFrame(
                        sampleBuffer: previewSampleBuffer,
                        presentationTime: CMTimeGetSeconds(
                            previewSampleBuffer.presentationTimeStamp),
                        isHDR: self.videoInfo.isHDR,
                        colorTransfer: Int(self.videoInfo.colorTransfer),
                        doviProfile: self.videoInfo.isDolbyVision
                            ? Int(self.videoInfo.doviProfile ?? 0) : 0,
                        ambientLightMetadata: firstPacket.ambientLightMetadata
                    )
                    previewHandler(previewFrame)
                }
            }

            var targetVideoPacket: FFmpegDemuxerPacket? = nil

            // Find the specific packet to "snap" to (closest to target time).
            for p in restorationPackets where p.isVideo {
                let ptsSeconds =
                    Double(p.pts) * Double(builder.timeBaseNum) / Double(builder.timeBaseDen)
                if ptsSeconds >= seconds - 0.05 {
                    targetVideoPacket = p
                    break
                }
            }

            // If not found in restoration packets, fetch the next one.
            if targetVideoPacket == nil {
                if let nextP = await demuxerActor.demuxNextPacket() {
                    restorationPackets.append(nextP)
                    if nextP.isVideo {
                        targetVideoPacket = nextP
                    }
                }
            }

            // Store packets for context restoration.
            performUnderLock {
                self.pendingContextRestorationPackets = restorationPackets
            }

            guard let finalPacket = targetVideoPacket else {
                return nil
            }

            // Create the frame immediately.
            let sampleBuffer = try builder.createSampleBuffer(
                from: finalPacket.data,
                pts: finalPacket.pts,
                dts: finalPacket.dts,
                duration: finalPacket.duration,
                forPassthrough: true,
                ambientLightMetadata: finalPacket.ambientLightMetadata
            )

            return VideoFrame(
                sampleBuffer: sampleBuffer,
                presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
                isHDR: self.videoInfo.isHDR,
                colorTransfer: Int(self.videoInfo.colorTransfer),
                doviProfile: self.videoInfo.isDolbyVision
                    ? Int(self.videoInfo.doviProfile ?? 0) : 0,
                ambientLightMetadata: finalPacket.ambientLightMetadata
            )
        }
        // Case B: FFmpeg / Software Decoding
        else if let decoderActor = self.decoderActor {
            var foundFrame: VideoFrame? = nil
            var isFirstVideoPacket = true

            for packet in restorationPackets {
                let data = self.convertPacket(packet)

                if packet.isVideo {
                    if let frames = await decoderActor.decodeVideoPacket(withAllFrames: data) {
                        for f in frames {
                            let currentFrame = self.makeVideoFrame(
                                pixelBuffer: f.pixelBuffer,
                                presentationTime: f.presentationTime,
                                doviProfile: Int(f.doviProfile),
                                ambientLightMetadata: f.ambientLightMetadata
                            )

                            // PREVIEW: Show the very first decoded frame (keyframe)
                            if isFirstVideoPacket, let previewHandler, let currentFrame {
                                previewHandler(currentFrame)
                                isFirstVideoPacket = false
                            }

                            // Check if we reached the target time.
                            if f.presentationTime >= seconds - 0.05 {
                                foundFrame = currentFrame
                                break
                            }
                        }
                    }
                } else if packet.isAudio {
                    _ = await decoderActor.decodeAudioPacket(withAllFrames: data)
                }

                if foundFrame != nil { break }
            }

            // If not found, continue fetching packets (handle decoder latency/reordering).
            if foundFrame == nil {
                var packetCount = 0
                // Try up to 24 packets (approx 1s at 24fps) to clear decoder buffers
                while foundFrame == nil && packetCount < 24 {
                    if let nextP = await demuxerActor.demuxNextPacket() {
                        let data = self.convertPacket(nextP)
                        if nextP.isVideo {
                            if let frames = await decoderActor.decodeVideoPacket(
                                withAllFrames: data)
                            {
                                if let f = frames.first {
                                    foundFrame = self.makeVideoFrame(
                                        pixelBuffer: f.pixelBuffer,
                                        presentationTime: f.presentationTime,
                                        doviProfile: Int(f.doviProfile),
                                        ambientLightMetadata: f.ambientLightMetadata
                                    )
                                }
                            }
                        }
                        packetCount += 1
                    } else {
                        break  // EOF
                    }
                }
            }

            // Clear restoration packets as they are already decoded.
            performUnderLock {
                self.pendingContextRestorationPackets.removeAll()
            }

            return foundFrame
        }

        return nil
    }
}
