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

        // 1. Eliminate Redundant Lock Operations: Combine state changes
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

        // 8. Reduce Task Cancellation Checks (Keep essential ones)
        try Task.checkCancellation()

        // 2. Parallel Flush and Seek Operations
        // Run flush and seek in parallel to reduce latency
        async let flushTask: Void? = self.decoderActor?.flushCodecBuffers()
        async let seekTask = demuxerActor.seek(toKeyframe: seconds)

        _ = await flushTask
        let seekSuccess = await seekTask

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

        // 4. Reduce Array Allocations in Packet Filtering / 3. Array Filtering
        // 9. Pre-size Arrays: filter handles allocation efficiently
        // Use filter instead of loop to avoid intermediate array resizing
        var restorationPackets = packets.filter { !$0.isAudio }

        // 10. Cache VideoInfo Properties
        let isPassThrough = self.hardwareDecodeMode == .passThrough
        
        // 5. Unified Processing

        // Case A: Hardware Passthrough
        if isPassThrough, let builder = self.sampleBufferBuilder {
            var targetVideoPacket: FFmpegDemuxerPacket? = nil

            // 5. Optimize PTS Calculation in Passthrough Loop
            // Pre-calculate multiplier to avoid division in the loop
            let ptsMultiplier = Double(builder.timeBaseNum) / Double(builder.timeBaseDen)
            let targetTime = seconds - 0.05
            
            // Find the specific packet to "snap" to (closest to target time).
            for p in restorationPackets where p.isVideo {
                let ptsSeconds = Double(p.pts) * ptsMultiplier
                if ptsSeconds >= targetTime {
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
            
            return createVideoFrame(
                sampleBuffer: sampleBuffer,
                presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
                ambientLightMetadata: finalPacket.ambientLightMetadata
            )
        }
        // Case B: FFmpeg / Software Decoding
        else if let decoderActor = self.decoderActor {
            var foundFrame: VideoFrame? = nil

            // 7. Optimize Software Decode Loop Break Condition
            // Use labeled break to exit nested loops immediately
            packetLoop: for packet in restorationPackets {
                let data = self.convertPacket(packet)

                if packet.isVideo {
                    if let frames = await decoderActor.decodeVideoPacket(withAllFrames: data) {
                        for f in frames {
                            let currentFrame = self.createVideoFrame(
                                pixelBuffer: f.pixelBuffer,
                                presentationTime: f.presentationTime,
                                doviProfile: Int(f.doviProfile),
                                ambientLightMetadata: f.ambientLightMetadata
                            )

                            // Check if we reached the target time.
                            if f.presentationTime >= seconds - 0.05 {
                                foundFrame = currentFrame
                                break packetLoop
                            }
                        }
                    }
                } else if packet.isAudio {
                    _ = await decoderActor.decodeAudioPacket(withAllFrames: data)
                }
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
                                    foundFrame = self.createVideoFrame(
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
