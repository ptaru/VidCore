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
  public func seek(to seconds: Double) async throws -> VideoFrame? {
    // Acquire lock to check state
    if checkIsClosed() {
        return nil
    }

    // Dispatch based on available decoder
    if self.hardwareDecodeMode == .passThrough, self.sampleBufferBuilder != nil {
      return try await self.seekPassthrough(to: seconds)
    } else if self.decoderActor != nil {
      return try await self.seekFFmpeg(to: seconds)
    } else {
      throw NSError(
          domain: "MediaDecoder", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "Seek failed - decoder unavailable"])
    }
  }

  private func seekPassthrough(to seconds: Double) async throws -> VideoFrame? {
    guard let builder = self.sampleBufferBuilder else { return nil }

    performUnderLock {
      // Clear pending packets locally
      self.pendingContextRestorationPackets.removeAll()
    }

    // Passthrough path: use demuxer for seeking and getting packets
    // Flush decoder to reset internal state (critical for audio PTS monotonicity reset)
    await self.decoderActor?.flushCodecBuffers()

    let seekSuccess = await demuxerActor.seek(toKeyframe: seconds)
    guard seekSuccess else {
      throw NSError(
        domain: "MediaDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed - seek error"])
    }

    // Collect packets from demuxer
    // Always collect until target for accurate seek
    guard let packets = await demuxerActor.collectPackets(until: seconds), !packets.isEmpty else {
      throw NSError(
        domain: "MediaDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed - no packets"])
    }

    if self.hardwareDecodeMode == .passThrough {
      // Passthrough seek: return a compressed sample buffer without decompression.
      // We still queue the GOP for AVSampleBufferDisplayLayer to rebuild context.
      var targetPacket: FFmpegDemuxerPacket?
      var firstKeyframe: FFmpegDemuxerPacket?
      var firstAfterTarget: FFmpegDemuxerPacket?
      var lastPacket: FFmpegDemuxerPacket?

      for packet in packets {
        lastPacket = packet
        if packet.isKeyframe, firstKeyframe == nil {
          firstKeyframe = packet
        }
        if firstAfterTarget == nil, packet.pts != Int64.min {
          let packetSeconds =
            Double(packet.pts) * Double(builder.timeBaseNum) / Double(builder.timeBaseDen)
          if packetSeconds >= seconds - 0.01 {
            firstAfterTarget = packet
          }
        }
      }

      if let candidate = firstAfterTarget, candidate.isKeyframe {
        targetPacket = candidate
      } else if let keyframe = firstKeyframe {
        targetPacket = keyframe
      } else {
        targetPacket = firstAfterTarget ?? lastPacket
      }

      performUnderLock {
        if let targetPacket, targetPacket.isKeyframe {
          self.pendingContextRestorationPackets = packets.filter { $0 !== targetPacket }
        } else {
          self.pendingContextRestorationPackets = packets
        }
      }

      guard let packet = targetPacket else {
        throw NSError(
          domain: "MediaDecoder", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "Seek failed - no packet found"])
      }

      // Convert demuxer packet to usable data for sample buffer
      // Note: original code used packet.data directly from FFmpegDemuxerPacket.
      // Safe to use here as long as we hold the reference.
      
      let sampleBuffer = try builder.createSampleBuffer(
        from: packet.data,
        pts: packet.pts,
        dts: packet.dts,
        duration: packet.duration,
        forPassthrough: true,
        ambientLightMetadata: packet.ambientLightMetadata
      )

      let frame = VideoFrame(
        sampleBuffer: sampleBuffer,
        presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
        isHDR: self.videoInfo.isHDR,
        colorTransfer: Int(self.videoInfo.colorTransfer),
        doviProfile: self.videoInfo.isDolbyVision ? Int(self.videoInfo.doviProfile ?? 0) : 0,
        ambientLightMetadata: packet.ambientLightMetadata
      )
      return frame
    }

    throw NSError(
      domain: "MediaDecoder", code: -3,
      userInfo: [NSLocalizedDescriptionKey: "Seek failed - passthrough only path"])
  }

  private func seekFFmpeg(to seconds: Double) async throws -> VideoFrame? {
    guard let decoderActor = self.decoderActor else { return nil }

    // Non-passthrough path: use demuxer to seek, decoder to decode

    // Flush decoder buffers to clear state (fix for replay issues)
    await decoderActor.flushCodecBuffers()

    let seekSuccess = await demuxerActor.seek(toKeyframe: seconds)
    guard seekSuccess else {
      throw NSError(
        domain: "MediaDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed"])
    }

    // Robust Seek Loop: Feed packets until we get a frame
    var foundFrame: VideoFrame? = nil
    var packetCount = 0
    let maxPackets = 200  // Safety break

    // Pre-collect audio
    if let initialPackets = await demuxerActor.collectPackets(until: seconds) {
      for demuxerPacket in initialPackets {
        if packetCount >= maxPackets { break }
        
        if demuxerPacket.isVideo {
            packetCount += 1
            let packet = self.convertPacket(demuxerPacket)
            if let ffmpegFrames = await decoderActor.decodeVideoPacket(withAllFrames: packet) {
                for ffmpegFrame in ffmpegFrames {
                   let framePTS = ffmpegFrame.presentationTime
                   if framePTS >= seconds - 0.05 {
                        if let frame = self.makeVideoFrame(
                          pixelBuffer: ffmpegFrame.pixelBuffer,
                          presentationTime: framePTS,
                          doviProfile: Int(ffmpegFrame.doviProfile),
                          ambientLightMetadata: ffmpegFrame.ambientLightMetadata
                        ) {
                          foundFrame = frame
                          break
                        }
                   }
                }
            }
        }
        if foundFrame != nil { break }
      }
    }

    while packetCount < maxPackets, foundFrame == nil {
        if let demuxerPacket = await demuxerActor.demuxNextPacket() {
             if demuxerPacket.isVideo {
                packetCount += 1
                let packet = self.convertPacket(demuxerPacket)
                if let ffmpegFrames = await decoderActor.decodeVideoPacket(withAllFrames: packet) {
                    for ffmpegFrame in ffmpegFrames {
                       let framePTS = ffmpegFrame.presentationTime
                       if framePTS >= seconds - 0.05 {
                            if let frame = self.makeVideoFrame(
                              pixelBuffer: ffmpegFrame.pixelBuffer,
                              presentationTime: framePTS,
                              doviProfile: Int(ffmpegFrame.doviProfile),
                              ambientLightMetadata: ffmpegFrame.ambientLightMetadata
                            ) {
                              foundFrame = frame
                              break
                            }
                       }
                    }
                }
             }
        } else {
            break // EOF
        }
    }

    if let frame = foundFrame {
      return frame
    } else {
      throw NSError(
        domain: "MediaDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed - no suitable frame found"])
    }
  }
}
