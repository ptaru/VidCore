//
//  VideoFrame.swift
//  VidCore
//
//  Wrapper for decoded video frames
//

import CoreMedia
import CoreVideo
import Foundation

/// A decoded video frame containing pixel data and timing information.
///
/// `VideoFrame` wraps a `CMSampleBuffer` with its presentation timestamp,
/// representing a single frame from a video stream. The data can be either
/// raw pixel data (decoded) or compressed data (passthrough).
///
/// ## Pixel Formats
/// The underlying buffer may be:
/// - **Compressed** (hevc/h264): `CMSampleBuffer` contains compressed block buffer
/// - **NV12** (hardware-decoded): `pixelBuffer` contains `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
/// - **I420** (software-decoded): `pixelBuffer` contains `kCVPixelFormatType_420YpCbCr8Planar`
/// - **P010** (10-bit HDR): `pixelBuffer` contains `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`
///
/// The ``RenderingEngine`` handles uncompressed formats automatically via GPU shaders.
/// Compressed frames must be fed to `AVSampleBufferDisplayLayer`.
public struct VideoFrame: @unchecked Sendable {
  /// The underlying sample buffer (compressed or uncompressed).
  public let sampleBuffer: CMSampleBuffer

  /// The raw pixel data for this frame, if available.
  /// Returns `nil` if the frame is compressed (passthrough).
  public var pixelBuffer: CVPixelBuffer? {
    CMSampleBufferGetImageBuffer(sampleBuffer)
  }

  /// The presentation timestamp in seconds from the start of the video.
  public let presentationTime: Double

  /// Whether this frame contains HDR content (PQ or HLG transfer function).
  public let isHDR: Bool

  /// Color transfer characteristics (1=BT.709, 16=PQ, 18=HLG).
  public let colorTransfer: Int

  /// Dolby Vision Profile ID (e.g., 5, 8), 0 if not present.
  public let doviProfile: Int

  /// Per-frame Ambient Viewing Environment metadata (AVAmbientViewingEnvironment).
  public let ambientLightMetadata: Data?

  /// Whether the frame is compressed (contains no pixel buffer).
  public var isCompressed: Bool {
    pixelBuffer == nil
  }

  /// Creates a video frame from a sample buffer.
  /// - Parameters:
  ///   - sampleBuffer: The underlying sample buffer.
  ///   - presentationTime: The presentation timestamp in seconds.
  ///   - isHDR: Whether the frame is HDR.
  ///   - colorTransfer: The color transfer characteristic.
  ///   - doviProfile: The Dolby Vision profile ID.
  public init(
    sampleBuffer: CMSampleBuffer,
    presentationTime: Double,
    isHDR: Bool = false,
    colorTransfer: Int? = nil,
    doviProfile: Int = 0,
    ambientLightMetadata: Data? = nil
  ) {
    self.sampleBuffer = sampleBuffer
    self.presentationTime = presentationTime
    self.isHDR = isHDR
    self.colorTransfer = colorTransfer ?? (isHDR ? 16 : 1)
    self.doviProfile = doviProfile
    self.ambientLightMetadata = ambientLightMetadata
  }

  /// Creates a video frame from a pixel buffer.
  /// - Parameters:
  ///   - pixelBuffer: The underlying pixel buffer.
  ///   - presentationTime: The presentation timestamp in seconds.
  ///   - isHDR: Whether the frame is HDR.
  ///   - colorTransfer: The color transfer characteristic.
  ///   - doviProfile: The Dolby Vision profile ID.
  public init?(
    pixelBuffer: CVPixelBuffer,
    presentationTime: Double,
    isHDR: Bool = false,
    colorTransfer: Int? = nil,
    doviProfile: Int = 0,
    ambientLightMetadata: Data? = nil
  ) {
    // Create a basic CMSampleBuffer wrapping the pixel buffer
    // Note: In a real app we might want to cache the format description
    var sampleBuffer: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMTime(seconds: presentationTime, preferredTimescale: 60000),
      decodeTimeStamp: .invalid
    )

    var formatDesc: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDesc
    )

    if let fd = formatDesc {
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: fd,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      )
    }

    guard let sbuf = sampleBuffer else {
      return nil
    }
    self.sampleBuffer = sbuf

    self.presentationTime = presentationTime
    self.isHDR = isHDR
    self.colorTransfer = colorTransfer ?? (isHDR ? 16 : 1)
    self.doviProfile = doviProfile
    self.ambientLightMetadata = ambientLightMetadata
  }

  /// Applies HDR attachments (Color Primaries, Transfer Function, YCbCr Matrix) to the pixel buffer if missing.
  /// This is often necessary for software-decoded frames or when converting formats.
  public func applyHDRAttachments() {
    guard let pixelBuffer = pixelBuffer, isHDR else { return }

    let attachments = [
      kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
      kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
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
      if colorTransfer == 18 {  // HLG
        transferFunction = TransferFunction_HLG
      } else {  // PQ (ST 2084)
        transferFunction = TransferFunction_PQ
      }
      CVBufferSetAttachment(
        pixelBuffer, kCVImageBufferTransferFunctionKey, transferFunction, .shouldPropagate)
    }
  }
}
