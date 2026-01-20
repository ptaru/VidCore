//
//  VideoFrame.swift
//  VidCore
//
//  Swift wrapper for decoded video frames
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
    /// Dolby Vision Profile 5 metadata, if present.
    public let doviMetadata: DoViMetadata?
    /// Color transfer characteristics (1=BT.709, 16=PQ, 18=HLG).
    public let colorTransfer: Int

    /// Creates a video frame (SDR content).
    public init(pixelBuffer: CVPixelBuffer, presentationTime: Double) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.isHDR = false
        self.doviMetadata = nil
        self.colorTransfer = 1 // BT.709 default for SDR
    }
    
    /// Creates a video frame with HDR flag.
    public init(pixelBuffer: CVPixelBuffer, presentationTime: Double, isHDR: Bool) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.isHDR = isHDR
        self.doviMetadata = nil
        self.colorTransfer = isHDR ? 16 : 1 // Default to PQ for HDR
    }
    
    /// Creates a video frame with Dolby Vision metadata.
    public init(pixelBuffer: CVPixelBuffer, presentationTime: Double, isHDR: Bool, doviMetadata: DoViMetadata?) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.isHDR = isHDR
        self.doviMetadata = doviMetadata
        self.colorTransfer = isHDR ? 16 : 1 // Default to PQ for HDR
    }
    
    /// Creates a video frame with explicit color transfer characteristics.
    public init(pixelBuffer: CVPixelBuffer, presentationTime: Double, isHDR: Bool, doviMetadata: DoViMetadata?, colorTransfer: Int) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.isHDR = isHDR
        self.doviMetadata = doviMetadata
        self.colorTransfer = colorTransfer
    }
}

