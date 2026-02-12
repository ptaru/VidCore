//
//  MediaDecoder+Helpers.swift
//  VidCore
//

import CoreVideo
import Foundation

extension MediaDecoder {
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
