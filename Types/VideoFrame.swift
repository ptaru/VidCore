//
//  VideoFrame.swift
//  VidCore
//
//  Wrapper for decoded video frames
//

import CoreVideo
import Foundation

/// A decoded video frame containing pixel data and timing information.
///
/// `VideoFrame` wraps a `CVPixelBuffer` with its presentation timestamp,
/// representing a single frame from a video stream. The pixel buffer can
/// be rendered directly via ``RenderingEngine`` or converted to other formats.
///
/// ## Pixel Formats
/// The underlying pixel buffer may be in various formats depending on the decoder:
/// - **NV12** (hardware-decoded): `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
/// - **I420** (software-decoded): `kCVPixelFormatType_420YpCbCr8Planar`
/// - **P010** (10-bit HDR): `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`
/// - **BGRA** (fallback): `kCVPixelFormatType_32BGRA`
///
/// The ``RenderingEngine`` handles all formats automatically via GPU shaders.
public struct VideoFrame {
    /// The raw pixel data for this frame.
    public let pixelBuffer: CVPixelBuffer
    /// The presentation timestamp in seconds from the start of the video.
    public let presentationTime: Double
    /// Whether this frame contains HDR content (PQ or HLG transfer function).
    public let isHDR: Bool
    /// Color transfer characteristics (1=BT.709, 16=PQ, 18=HLG).
    public let colorTransfer: Int
    /// Dolby Vision Profile ID (e.g., 5, 8), 0 if not present.
    public let doviProfile: Int


    /// Creates a video frame with full control over metadata and color characteristics.
    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: Double,
        isHDR: Bool = false,
        colorTransfer: Int? = nil,
        doviProfile: Int = 0
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.isHDR = isHDR
        self.colorTransfer = colorTransfer ?? (isHDR ? 16 : 1)
        self.doviProfile = doviProfile
    }
    /// Applies HDR attachments (Color Primaries, Transfer Function, YCbCr Matrix) to the pixel buffer if missing.
    /// This is often necessary for software-decoded frames or when converting formats.
    public func applyHDRAttachments() {
        guard isHDR else { return }
        
        let attachments = [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020
        ]
        
        for (key, value) in attachments {
            if CVBufferCopyAttachment(pixelBuffer, key, nil) == nil {
                CVBufferSetAttachment(pixelBuffer, key, value, .shouldPropagate)
            }
        }
        
        // Transfer Function
        if CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) == nil {
            let TransferFunction_HLG = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            let TransferFunction_PQ = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            
            let transferFunction: CFString
            if colorTransfer == 18 { // HLG
                transferFunction = TransferFunction_HLG
            } else { // PQ (ST 2084)
                transferFunction = TransferFunction_PQ
            }
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, transferFunction, .shouldPropagate)
        }
    }
}
