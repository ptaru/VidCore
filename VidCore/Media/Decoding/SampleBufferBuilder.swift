//
//  SampleBufferBuilder.swift
//  VidCore
//
//  Builds CMSampleBuffer instances for passthrough playback (no decoding).
//

import CoreMedia
import CoreVideo
import Foundation

// MARK: - Error Types

/// Errors that can occur during SampleBufferBuilder operations.
public enum SampleBufferBuilderError: Error, LocalizedError {
  case noExtradata
  case formatDescriptionCreationFailed(OSStatus)
  case blockBufferCreationFailed(OSStatus)
  case sampleBufferCreationFailed(OSStatus)
  case unsupportedCodec

  public var errorDescription: String? {
    switch self {
    case .noExtradata:
      return "No extradata found for stream"
    case .formatDescriptionCreationFailed(let status):
      return "CMVideoFormatDescriptionCreate failed: \(status)"
    case .blockBufferCreationFailed(let status):
      return "CMBlockBuffer creation failed: \(status)"
    case .sampleBufferCreationFailed(let status):
      return "CMSampleBuffer creation failed: \(status)"
    case .unsupportedCodec:
      return "Unsupported codec for SampleBufferBuilder"
    }
  }
}

// MARK: - Configuration Types

/// Supported video codecs for SampleBufferBuilder.
public enum SampleBufferBuilderCodec {
  case hevc
  case h264
}

/// Configuration for initializing a SampleBufferBuilder.
public struct SampleBufferBuilderConfig {
  public let codec: SampleBufferBuilderCodec
  public let width: Int32
  public let height: Int32
  public let extradata: Data
  public let timeBaseNum: Int32
  public let timeBaseDen: Int32

  // Color metadata
  public let colorPrimaries: Int32
  public let colorTransfer: Int32
  public let colorSpace: Int32

  // Optional Dolby Vision configuration
  public let dolbyVisionConfig: Data?

  /// Creates a new sample buffer builder configuration.
  public init(
    codec: SampleBufferBuilderCodec,
    width: Int32,
    height: Int32,
    extradata: Data,
    timeBaseNum: Int32,
    timeBaseDen: Int32,
    colorPrimaries: Int32 = 0,
    colorTransfer: Int32 = 0,
    colorSpace: Int32 = 0,
    dolbyVisionConfig: Data? = nil
  ) {
    self.codec = codec
    self.width = width
    self.height = height
    self.extradata = extradata
    self.timeBaseNum = timeBaseNum
    self.timeBaseDen = timeBaseDen
    self.colorPrimaries = colorPrimaries
    self.colorTransfer = colorTransfer
    self.colorSpace = colorSpace
    self.dolbyVisionConfig = dolbyVisionConfig
  }
}

/// Builds CMSampleBuffer instances for passthrough playback.
public final class SampleBufferBuilder: @unchecked Sendable {

  // MARK: - Properties

  private var formatDescription: CMVideoFormatDescription?
  public let timeBaseNum: Int32
  public let timeBaseDen: Int32

  // Dolby Vision
  public private(set) var isDolbyVision: Bool = false
  public private(set) var isHDR: Bool = false
  public private(set) var dolbyVisionProfile: UInt8 = 0
  private var dvcCData: Data?

  // DTS Monotonicity Tracking (used for non-passthrough sample buffers)
  private var lastDecodeStartTime: CMTime = .invalid

  // MARK: - Initialization

  /// Check if a codec is supported by SampleBufferBuilder.
  /// - Parameter codec: The codec to check.
  /// - Returns: `true` if the codec is supported.
  public static func isCodecSupported(_ codec: SampleBufferBuilderCodec) -> Bool {
    return codec == .hevc || codec == .h264
  }

  /// Initialize the builder with configuration.
  /// - Parameter config: The configuration for the builder.
  /// - Throws: `SampleBufferBuilderError` if initialization fails.
  public init(config: SampleBufferBuilderConfig) throws {
    self.timeBaseNum = config.timeBaseNum
    self.timeBaseDen = config.timeBaseDen

    // Detect HDR content (16 = PQ, 18 = HLG)
    self.isHDR = config.colorTransfer == 16 || config.colorTransfer == 18

    // Process Dolby Vision configuration if provided
    if let doviConfig = config.dolbyVisionConfig, doviConfig.count >= 8 {
      processDolbyVisionConfig(doviConfig)
    }

    // Create format description
    try createFormatDescription(config: config)
  }

  deinit {
    formatDescription = nil
  }

  // MARK: - Dolby Vision Processing

  private func processDolbyVisionConfig(_ doviConfig: Data) {
    // FFmpeg's AVDOVIDecoderConfigurationRecord is an UNPACKED struct:
    //   uint8_t dv_version_major;     // offset 0
    //   uint8_t dv_version_minor;     // offset 1
    //   uint8_t dv_profile;           // offset 2
    //   uint8_t dv_level;             // offset 3
    //   uint8_t rpu_present_flag;     // offset 4
    //   uint8_t el_present_flag;      // offset 5
    //   uint8_t bl_present_flag;      // offset 6
    //   uint8_t dv_bl_signal_compatibility_id; // offset 7

    doviConfig.withUnsafeBytes { ptr in
      guard let bytes = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

      let dvVersionMajor = bytes[0]
      let dvVersionMinor = bytes[1]
      let dvProfile = bytes[2]
      let dvLevel = bytes[3]
      let rpuPresentFlag = bytes[4]
      let elPresentFlag = bytes[5]
      let blPresentFlag = bytes[6]
      let dvBlSignalCompatibilityId = bytes[7]

      // For Profile 7, we strip DoVi metadata to let it act as HDR10
      if dvProfile == 7 {
        self.dolbyVisionProfile = 7
        return
      }

      self.isDolbyVision = true
      self.dolbyVisionProfile = dvProfile

      // Reconstruct the BIT-PACKED dvcC atom format for VideoToolbox:
      // The dvcC record is 24 bytes total according to actual MP4 files.
      var dvcC = [UInt8](repeating: 0, count: 24)
      dvcC[0] = dvVersionMajor
      dvcC[1] = dvVersionMinor
      dvcC[2] = (dvProfile << 1) | ((dvLevel >> 5) & 0x01)
      dvcC[3] =
        ((dvLevel & 0x1F) << 3) | ((rpuPresentFlag & 0x01) << 2) | ((elPresentFlag & 0x01) << 1)
        | (blPresentFlag & 0x01)
      dvcC[4] = (dvBlSignalCompatibilityId & 0x0F) << 4

      self.dvcCData = Data(dvcC)
    }
  }

  // MARK: - Format Description Creation

  private func createFormatDescription(config: SampleBufferBuilderConfig) throws {
    guard !config.extradata.isEmpty else {
      throw SampleBufferBuilderError.noExtradata
    }

    // Determine codec type and atom key
    let codecType: CMVideoCodecType
    let atomKey: String

    switch config.codec {
    case .hevc:
      codecType = kCMVideoCodecType_HEVC
      atomKey = "hvcC"
    case .h264:
      codecType = kCMVideoCodecType_H264
      atomKey = "avcC"
    }

    // Build atoms dictionary
    var atoms: [String: Data] = [atomKey: config.extradata]

    // Add dvcC atom for Dolby Vision content
    if isDolbyVision, let dvcC = dvcCData {
      atoms["dvcC"] = dvcC
    }

    // Build extensions dictionary
    var extensions: [String: Any] = [
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: atoms
    ]

    // Add color metadata
    // Color Primaries
    if config.colorPrimaries == 9 {  // BT.2020
      extensions[kCVImageBufferColorPrimariesKey as String] =
        kCVImageBufferColorPrimaries_ITU_R_2020
    } else if config.colorPrimaries == 1 {  // BT.709
      extensions[kCVImageBufferColorPrimariesKey as String] =
        kCVImageBufferColorPrimaries_ITU_R_709_2
    }

    // Transfer Function
    if config.colorTransfer == 16 {  // PQ
      extensions[kCVImageBufferTransferFunctionKey as String] =
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    } else if config.colorTransfer == 18 {  // HLG
      extensions[kCVImageBufferTransferFunctionKey as String] =
        kCVImageBufferTransferFunction_ITU_R_2100_HLG
    } else if config.colorTransfer == 1 {  // BT.709
      extensions[kCVImageBufferTransferFunctionKey as String] =
        kCVImageBufferTransferFunction_ITU_R_709_2
    } else if config.colorTransfer == 0 || config.colorTransfer == 2 {
      // Unspecified - if DoVi Profile 5, it uses PQ curve (IPTPQc2)
      if isDolbyVision && dolbyVisionProfile == 5 {
        extensions[kCVImageBufferTransferFunctionKey as String] =
          kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
      }
    }

    // YCbCr Matrix
    if config.colorSpace == 9 {  // BT.2020_NCL
      extensions[kCVImageBufferYCbCrMatrixKey as String] = kCVImageBufferYCbCrMatrix_ITU_R_2020
    } else if config.colorSpace == 1 {  // BT.709
      extensions[kCVImageBufferYCbCrMatrixKey as String] = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }

    var formatDesc: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      codecType: codecType,
      width: config.width,
      height: config.height,
      extensions: extensions as CFDictionary,
      formatDescriptionOut: &formatDesc
    )

    guard status == noErr, let desc = formatDesc else {
      throw SampleBufferBuilderError.formatDescriptionCreationFailed(status)
    }

    self.formatDescription = desc
  }

  // MARK: - Sample Buffer Creation

  /// Creates a CMSampleBuffer from raw packet data.
  /// This is used internally for passthrough (zero-copy) rendering.
  /// - Parameters:
  ///   - data: The raw packet data.
  ///   - pts: The presentation timestamp.
  ///   - dts: The decoding timestamp.
  ///   - duration: The sample duration.
  ///   - forPassthrough: Whether this is for passthrough rendering.
  /// - Returns: A new CMSampleBuffer.
  /// - Throws: `SampleBufferBuilderError` if creation fails.
  public func createSampleBuffer(
    from data: Data,
    pts: Int64,
    dts: Int64,
    duration: Int64,
    forPassthrough: Bool = false,
    ambientLightMetadata: Data? = nil
  ) throws -> CMSampleBuffer {
    guard !data.isEmpty else {
      throw SampleBufferBuilderError.blockBufferCreationFailed(-1)
    }

    // Zero-Copy Optimization:
    // Instead of creating an empty BlockBuffer and copying into it (double handling),
    // we allocate memory via malloc, copy once, and hand ownership to CMBlockBuffer.

    let size = data.count
    // Allocate memory (malloc)
    guard let rawPtr = malloc(size) else {
      throw SampleBufferBuilderError.blockBufferCreationFailed(-1)
    }

    // Copy data to the allocated buffer
    data.withUnsafeBytes { ptr in
      if let baseAddress = ptr.baseAddress {
        memcpy(rawPtr, baseAddress, size)
      }
    }

    // Create CMBlockBuffer wrapping our malloc'd memory
    // kCFAllocatorMalloc ensures needed cleanup (free) when BlockBuffer is released.
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: rawPtr,
      blockLength: size,
      blockAllocator: kCFAllocatorMalloc,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: size,
      flags: 0,
      blockBufferOut: &blockBuffer
    )

    guard status == noErr, let block = blockBuffer else {
      // If creation fails, we must free manually as ownership wasn't transferred
      free(rawPtr)
      throw SampleBufferBuilderError.blockBufferCreationFailed(status)
    }

    // Create timing info
    var timingInfo = CMSampleTimingInfo()
    if duration > 0 {
      timingInfo.duration = CMTime(value: duration * Int64(timeBaseNum), timescale: timeBaseDen)
    } else {
      timingInfo.duration = .invalid
    }

    // Presentation Time Stamp (PTS)
    timingInfo.presentationTimeStamp =
      pts != Int64.min ? CMTime(value: pts * Int64(timeBaseNum), timescale: timeBaseDen) : .invalid

    // Decode Time Stamp (DTS) logic
    // AVSampleBufferDisplayLayer requires strictly monotonic DTS.
    // Non-monotonic or invalid DTS causes stutter or dropped frames.

    let inputDTS: CMTime
    if dts != Int64.min {
      inputDTS = CMTime(value: dts * Int64(timeBaseNum), timescale: timeBaseDen)
    } else {
      // Fallback: If no DTS, use PTS (only valid if no B-frames/reordering)
      inputDTS = timingInfo.presentationTimeStamp
    }

    if forPassthrough {
      // Preserve original DTS to avoid decode-after-present scenarios.
      timingInfo.decodeTimeStamp = inputDTS.isValid ? inputDTS : .invalid
    } else {
      // Monotonicity Enforcement
      if lastDecodeStartTime.isValid {
        if !inputDTS.isValid || inputDTS <= lastDecodeStartTime {
          // Invalid or non-monotonic: Synthesize based on last DTS + duration (or small epsilon)
          // Use duration from timingInfo if valid, else default to 1/60s approximation or just +1 timescale
          let step =
            timingInfo.duration.isValid
            ? timingInfo.duration : CMTime(value: 1, timescale: timeBaseDen)
          timingInfo.decodeTimeStamp = lastDecodeStartTime + step
        } else {
          // Valid monotonic input
          timingInfo.decodeTimeStamp = inputDTS
        }
      } else {
        // First frame
        timingInfo.decodeTimeStamp = inputDTS.isValid ? inputDTS : timingInfo.presentationTimeStamp
      }

      // Update tracking
      lastDecodeStartTime = timingInfo.decodeTimeStamp
    }

    // Create sample buffer
    var sampleBuffer: CMSampleBuffer?
    var sampleSize = data.count
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: block,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timingInfo,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )

    guard status == noErr, let sample = sampleBuffer else {
      throw SampleBufferBuilderError.sampleBufferCreationFailed(status)
    }

    if let ambientData = ambientLightMetadata {
      let key = "AmbientViewingEnvironment" as CFString
      CMSetAttachment(
        sample,
        key: key,
        value: ambientData as CFData,
        attachmentMode: kCMAttachmentMode_ShouldPropagate
      )
    }

    return sample
  }
}
