//
//  MediaDecoder+Helpers.swift
//  VidCore
//

import CoreVideo
import Foundation

extension MediaDecoder {
    /// Convert FFmpegDemuxerPacket to FFmpegPacketData for API compatibility.
    func convertPacket(_ demuxerPacket: FFmpegDemuxerPacket) -> FFmpegPacketData {
        let packet = FFmpegPacketData()
        packet.data = demuxerPacket.data
        packet.size = Int32(truncatingIfNeeded: demuxerPacket.size)
        packet.pts = demuxerPacket.pts
        packet.dts = demuxerPacket.dts
        packet.duration = demuxerPacket.duration
        packet.isVideo = demuxerPacket.isVideo
        packet.isAudio = demuxerPacket.isAudio
        packet.isSubtitle = demuxerPacket.isSubtitle
        packet.flags = demuxerPacket.isKeyframe ? 1 : 0  // AV_PKT_FLAG_KEY = 1
        packet.ambientLightMetadata = demuxerPacket.ambientLightMetadata
        return packet
    }

    func makeVideoFrame(
        pixelBuffer: CVPixelBuffer,
        presentationTime: Double,
        doviProfile: Int,
        ambientLightMetadata: Data?
    ) -> VideoFrame? {
        return VideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            isHDR: self.videoInfo.isHDR,
            colorTransfer: self.videoInfo.colorTransfer,
            doviProfile: doviProfile,
            ambientLightMetadata: ambientLightMetadata
        )
    }
}
