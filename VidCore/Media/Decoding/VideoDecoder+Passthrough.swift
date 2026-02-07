//
//  VideoDecoder+Passthrough.swift
//  VidCore
//

import CoreMedia

extension VideoDecoder {
  /// Consumes and returns any pending passthrough frames needed for context restoration.
  public func consumePendingPassthroughFrames() async -> [VideoFrame] {
    await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: [])
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed,
          self.hardwareDecodeMode == .passThrough,
          let builder = self.sampleBufferBuilder,
          !self.pendingContextRestorationPackets.isEmpty
        else {
          continuation.resume(returning: [])
          return
        }

        let packets = self.pendingContextRestorationPackets
        self.pendingContextRestorationPackets.removeAll()

        var frames: [VideoFrame] = []
        frames.reserveCapacity(packets.count)

        for packet in packets {
          do {
            let sampleBuffer = try builder.createSampleBuffer(
              from: packet.data,
              pts: packet.pts,
              dts: packet.dts,
              duration: packet.duration,
              forPassthrough: true
            )

            let frame = VideoFrame(
              sampleBuffer: sampleBuffer,
              presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
              isHDR: self.videoInfo.isHDR,
              colorTransfer: Int(self.videoInfo.colorTransfer),
              doviProfile: self.videoInfo.isDolbyVision ? Int(self.videoInfo.doviProfile ?? 0) : 0
            )
            frames.append(frame)
          } catch {
          }
        }

        continuation.resume(returning: frames)
      }
    }
  }
}
