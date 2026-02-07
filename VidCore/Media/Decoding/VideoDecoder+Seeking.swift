//
//  VideoDecoder+Seeking.swift
//  VidCore
//

import CoreMedia
import Foundation

extension VideoDecoder {
  /// Seeks to a specific time in the video.
  /// - Parameter seconds: The target time in seconds.
  /// - Returns: The first video frame at or after the seek target, or `nil`.
  /// - Throws: An error if the seek operation fails.
  public func seek(to seconds: Double) async throws -> VideoFrame? {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<VideoFrame?, Error>) in
      demuxQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: nil)
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed else {
          continuation.resume(returning: nil)
          return
        }

        // Dispatch based on available decoder
        if self.hardwareDecodeMode == .passThrough, self.sampleBufferBuilder != nil {
          do {
            let frame = try self.seekPassthrough(to: seconds)
            continuation.resume(returning: frame)
          } catch {
            continuation.resume(throwing: error)
          }
        } else if self.decoder != nil {
          do {
            let frame = try self.seekFFmpeg(to: seconds)
            continuation.resume(returning: frame)
          } catch {
            continuation.resume(throwing: error)
          }
        } else {
          continuation.resume(
            throwing: NSError(
              domain: "VideoDecoder", code: -3,
              userInfo: [NSLocalizedDescriptionKey: "Seek failed - decoder unavailable"]))
        }
      }
    }
  }

  private func seekPassthrough(to seconds: Double) throws -> VideoFrame? {
    guard let demuxer = self.demuxer, let builder = self.sampleBufferBuilder else { return nil }

    // Clear pending packets
    self.pendingContextRestorationPackets.removeAll()

    // Passthrough path: use demuxer for seeking and getting packets
    // Flush decoder to reset internal state (critical for audio PTS monotonicity reset)
    self.decoder?.flushCodecBuffers()

    guard demuxer.seek(toKeyframe: seconds) else {
      throw NSError(
        domain: "VideoDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed - seek error"])
    }

    // Collect packets from demuxer
    // Always collect until target for accurate seek
    guard let packets = demuxer.collectPackets(until: seconds), !packets.isEmpty else {
      throw NSError(
        domain: "VideoDecoder", code: -3,
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

      if let targetPacket, targetPacket.isKeyframe {
        self.pendingContextRestorationPackets = packets.filter { $0 !== targetPacket }
      } else {
        self.pendingContextRestorationPackets = packets
      }

      guard let packet = targetPacket else {
        throw NSError(
          domain: "VideoDecoder", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "Seek failed - no packet found"])
      }

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
      domain: "VideoDecoder", code: -3,
      userInfo: [NSLocalizedDescriptionKey: "Seek failed - passthrough only path"])
  }

  private func seekFFmpeg(to seconds: Double) throws -> VideoFrame? {
    guard let demuxer = self.demuxer, let decoder = self.decoder else { return nil }

    // Non-passthrough path: use demuxer to seek, decoder to decode

    // Flush decoder buffers to clear state (fix for replay issues)
    decoder.flushCodecBuffers()

    guard demuxer.seek(toKeyframe: seconds) else {
      throw NSError(
        domain: "VideoDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed"])
    }

    // Robust Seek Loop: Feed packets until we get a frame
    var foundFrame: VideoFrame? = nil
    var packetCount = 0
    let maxPackets = 200  // Safety break

    func decodeVideoPacket(_ demuxerPacket: FFmpegDemuxerPacket) -> Bool {
      guard demuxerPacket.isVideo else { return false }
      packetCount += 1
      let packet = self.convertPacket(demuxerPacket)

      if let ffmpegFrames = decoder.decodeVideoPacket(withAllFrames: packet) {
        for ffmpegFrame in ffmpegFrames {
          let framePTS = ffmpegFrame.presentationTime

          // Always wait for target (accurate seek)
          if framePTS >= seconds - 0.05 {
            if let frame = self.makeVideoFrame(
              pixelBuffer: ffmpegFrame.pixelBuffer,
              presentationTime: framePTS,
              doviProfile: Int(ffmpegFrame.doviProfile),
              ambientLightMetadata: ffmpegFrame.ambientLightMetadata
            ) {
              foundFrame = frame
              return true
            }
          }
        }
      }
      return false
    }

    // Prime audio packets near the seek target for faster audio resume.
    if let initialPackets = demuxer.collectPackets(until: seconds) {
      for demuxerPacket in initialPackets {
        if packetCount >= maxPackets { break }
        if decodeVideoPacket(demuxerPacket) { break }
      }
    }

    while packetCount < maxPackets, foundFrame == nil {
      let shouldStop = autoreleasepool { () -> Bool in
        // Read next packet directly
        guard let demuxerPacket = demuxer.demuxNextPacket() else {
          return true  // EOF
        }

        if decodeVideoPacket(demuxerPacket) {
          return true
        }
        return false
      }

      if shouldStop {
        break
      }
    }

    if let frame = foundFrame {
      return frame
    } else {
      throw NSError(
        domain: "VideoDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed - no suitable frame found"])
    }
  }
}
