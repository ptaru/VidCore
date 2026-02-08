//
//  MediaDecoder+Passthrough.swift
//  VidCore
//

import CoreMedia

extension MediaDecoder {
    /// Consumes and returns any pending passthrough frames needed for context restoration.
    public func consumePendingPassthroughFrames() async -> [VideoFrame] {
        let packets = withLock {
            if isClosed || hardwareDecodeMode != .passThrough
                || pendingContextRestorationPackets.isEmpty
            {
                return [FFmpegDemuxerPacket]()
            }

            let packets = self.pendingContextRestorationPackets
            self.pendingContextRestorationPackets.removeAll()
            return packets
        }

        if packets.isEmpty {
            return []
        }

        guard let builder = self.sampleBufferBuilder else {
            return []
        }

        var frames: [VideoFrame] = []
        frames.reserveCapacity(packets.count)

        for packet in packets {
            do {
                let sampleBuffer = try builder.createSampleBuffer(
                    from: packet.data,
                    pts: packet.pts,
                    dts: packet.dts,
                    duration: packet.duration,
                    forPassthrough: true,
                    ambientLightMetadata: packet.ambientLightMetadata
                )

                // Mark as DoNotDisplay so AVSBDL decodes but doesn't show it
                let attachments = CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer, createIfNecessary: true)
                if let attachments = attachments as? [NSMutableDictionary],
                    let first = attachments.first
                {
                    first[kCMSampleAttachmentKey_DoNotDisplay] = kCFBooleanTrue
                }

                let frame = VideoFrame(
                    sampleBuffer: sampleBuffer,
                    presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
                    isHDR: self.videoInfo.isHDR,
                    colorTransfer: Int(self.videoInfo.colorTransfer),
                    doviProfile: self.videoInfo.isDolbyVision
                        ? Int(self.videoInfo.doviProfile ?? 0) : 0,
                    ambientLightMetadata: packet.ambientLightMetadata
                )
                frames.append(frame)
            } catch {
            }
        }

        return frames
    }
}
