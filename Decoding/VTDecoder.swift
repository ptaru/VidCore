//
//  VTDecoder.swift
//  VidCore
//
//  VideoToolbox decoder with actor-based concurrency
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - Context Objects

/// Context for a single frame being decoded.
private class VTFrameContext {
  let ambientMetadata: Data?

  init(ambientMetadata: Data?) {
    self.ambientMetadata = ambientMetadata
  }
}

// MARK: - Error Types

/// Errors that can occur during VTDecoder operations.
public enum VTDecoderError: Error, LocalizedError {
  case noExtradata
  case formatDescriptionCreationFailed(OSStatus)
  case sessionCreationFailed(OSStatus)
  case sessionNotActive
  case blockBufferCreationFailed(OSStatus)
  case sampleBufferCreationFailed(OSStatus)
  case decodeFailed(OSStatus)
  case unsupportedCodec

  public var errorDescription: String? {
    switch self {
    case .noExtradata:
      return "No extradata found for stream"
    case .formatDescriptionCreationFailed(let status):
      return "CMVideoFormatDescriptionCreate failed: \(status)"
    case .sessionCreationFailed(let status):
      return "VTDecompressionSessionCreate failed: \(status)"
    case .sessionNotActive:
      return "Decompression session not active"
    case .blockBufferCreationFailed(let status):
      return "CMBlockBuffer creation failed: \(status)"
    case .sampleBufferCreationFailed(let status):
      return "CMSampleBuffer creation failed: \(status)"
    case .decodeFailed(let status):
      return "VTDecompressionSessionDecodeFrame failed: \(status)"
    case .unsupportedCodec:
      return "Unsupported codec for VTDecoder"
    }
  }
}

// MARK: - Configuration Types

/// Supported video codecs for VTDecoder.
public enum VTDecoderCodec {
  case hevc
  case h264
}

/// Configuration for initializing a VTDecoder.
public struct VTDecoderConfig {
  public let codec: VTDecoderCodec
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

  public init(
    codec: VTDecoderCodec,
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

/// A decoded frame with pixel buffer and presentation timestamp.
public struct VTDecodedFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let presentationTime: CMTime

  public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
    self.pixelBuffer = pixelBuffer
    self.presentationTime = presentationTime
  }
  public func attachmentData(forKey key: CFString) -> Data? {
    if let value = CVBufferCopyAttachment(pixelBuffer, key, nil) as? Data {
      return value
    }
    return nil
  }
}

// MARK: - VTDecoder Actor

/// Thread-safe VideoToolbox decoder using Swift actor.
public final class VTDecoder: @unchecked Sendable {

  // MARK: - Properties

  private var decompressionSession: VTDecompressionSession?
  private var formatDescription: CMVideoFormatDescription?
  public let timeBaseNum: Int32
  public let timeBaseDen: Int32

  // Dolby Vision
  public private(set) var isDolbyVision: Bool = false
  public private(set) var isHDR: Bool = false
  public private(set) var dolbyVisionProfile: UInt8 = 0
  private var dvcCData: Data?

  // Async frame queue
  private var frameQueue: [VTDecodedFrame] = []
  private let queueLock = NSLock()

  // Performance tracking
  private var totalDecodeTime: TimeInterval = 0
  private var decodeCount: UInt = 0

  // Configuration

  /// Average decode duration in seconds (for debugging).
  public var averageDecodeDuration: TimeInterval {
    return decodeCount > 0 ? totalDecodeTime / Double(decodeCount) : 0
  }

  // MARK: - Initialization

  /// Check if a codec is supported by VTDecoder.
  public static func isCodecSupported(_ codec: VTDecoderCodec) -> Bool {
    return codec == .hevc || codec == .h264
  }

  /// Initialize the decoder with configuration.
  public init(config: VTDecoderConfig) throws {
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

    // Create decompression session
    try createDecompressionSession()
  }

  deinit {
    teardown()
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
        print(
          "[VTDecoder] Dolby Vision Profile 7 detected, STRIPPING DoVi metadata to act as HDR10")
        self.dolbyVisionProfile = 7
        return
      }

      self.isDolbyVision = true
      self.dolbyVisionProfile = dvProfile

      print(
        "[VTDecoder] Dolby Vision Profile \(dvProfile) Level \(dvLevel) detected (version \(dvVersionMajor).\(dvVersionMinor))"
      )
      print(
        "[VTDecoder] Flags: rpu=\(rpuPresentFlag) el=\(elPresentFlag) bl=\(blPresentFlag) compat_id=\(dvBlSignalCompatibilityId)"
      )

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

      let hexString = dvcC.map { String(format: "%02X", $0) }.joined()
      print("[VTDecoder] Reconstructed dvcC (24 bytes): \(hexString)")
    }
  }

  // MARK: - Format Description Creation

  private func createFormatDescription(config: VTDecoderConfig) throws {
    guard !config.extradata.isEmpty else {
      throw VTDecoderError.noExtradata
    }

    // Determine codec type and atom key
    let codecType: CMVideoCodecType
    let atomKey: String

    switch config.codec {
    case .hevc:
      if isDolbyVision {
        codecType = kCMVideoCodecType_DolbyVisionHEVC
        print("[VTDecoder] Using Dolby Vision HEVC codec type")
      } else {
        codecType = kCMVideoCodecType_HEVC
      }
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
      print("[VTDecoder] Attaching dvcC atom (\(dvcC.count) bytes)")
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
        print("[VTDecoder] Comparison: inferred PQ transfer for DoVi P5")
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
      throw VTDecoderError.formatDescriptionCreationFailed(status)
    }

    self.formatDescription = desc
  }

  // MARK: - Decompression Session Creation

  private func createDecompressionSession() throws {
    guard let formatDesc = formatDescription else {
      throw VTDecoderError.sessionNotActive
    }

    // Video decoder specification - request hardware acceleration
    let videoDecoderSpecification: [String: Any] = [
      kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
    ]

    // Destination image buffer attributes
    var destinationAttributes: [String: Any] = [
      kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    // For HDR (PQ/HLG) or Dolby Vision 10-bit content, request appropriate pixel format
    if (isDolbyVision
      && (dolbyVisionProfile == 5 || dolbyVisionProfile == 7 || dolbyVisionProfile == 8)) || isHDR
    {
      if isDolbyVision && dolbyVisionProfile == 5 {
        // Profile 5 (IPTPQc2) uses full range encoding
        destinationAttributes[kCVPixelBufferPixelFormatTypeKey as String] =
          kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        print("[VTDecoder] Requesting 10-bit FULL range pixel format for Dolby Vision Profile 5")
      } else {
        // Profile 7/8 (or standard HDR10/HLG) use video (limited) range
        destinationAttributes[kCVPixelBufferPixelFormatTypeKey as String] =
          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        print(
          "[VTDecoder] Requesting 10-bit video range pixel format for \(isDolbyVision ? "Dolby Vision Profile \(dolbyVisionProfile)" : "HDR content")"
        )
      }
    }

    // Create callback record pointing to our callback function
    var callbackRecord = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: decompressionOutputCallback,
      decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
    )

    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDesc,
      decoderSpecification: videoDecoderSpecification as CFDictionary,
      imageBufferAttributes: destinationAttributes as CFDictionary,
      outputCallback: &callbackRecord,
      decompressionSessionOut: &session
    )

    guard status == noErr, let sess = session else {
      throw VTDecoderError.sessionCreationFailed(status)
    }

    self.decompressionSession = sess

    // Apply initial properties
    updateSessionProperties()
  }

  private func updateSessionProperties() {
    guard let session = decompressionSession else { return }

    // kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata
    // This property defaults to true (unset), but we can explicitly set it.
    // It controls whether the decoder attaches HDR metadata (mastering display info, etc.)
    // to the output CVPixelBuffers.

    let propertyKey = kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata
    let value = kCFBooleanTrue

    let status = VTSessionSetProperty(session, key: propertyKey, value: value)
    if status != noErr {
      print("[VTDecoder] Failed to set PropagatePerFrameHDRDisplayMetadata to true: \(status)")
    } else {
      print("[VTDecoder] Set PropagatePerFrameHDRDisplayMetadata to true")
    }
  }

  // MARK: - Teardown

  private func teardown() {
    if let session = decompressionSession {
      VTDecompressionSessionInvalidate(session)
      decompressionSession = nil
    }
    formatDescription = nil

    queueLock.lock()
    frameQueue.removeAll()
    queueLock.unlock()
  }

  // MARK: - Frame Queue Management

  fileprivate func enqueueFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
    let frame = VTDecodedFrame(pixelBuffer: pixelBuffer, presentationTime: pts)
    queueLock.lock()
    frameQueue.append(frame)
    queueLock.unlock()
  }

  /// Retrieve the next available decoded frame from the internal queue.
  public func popFrame() -> VTDecodedFrame? {
    queueLock.lock()
    defer { queueLock.unlock() }

    guard !frameQueue.isEmpty else { return nil }
    return frameQueue.removeFirst()
  }

  // MARK: - Decoding (Synchronous)

  /// Decodes a packet synchronously and returns the resulting CVPixelBuffer.
  /// Note: Usage of this prevents pipelining.
  public func decodePacketSync(data: Data, pts: Int64, dts: Int64, duration: Int64) throws
    -> CVPixelBuffer?
  {
    // Ensure we have a valid session
    if decompressionSession == nil {
      if formatDescription != nil {
        try createDecompressionSession()
      } else {
        throw VTDecoderError.sessionNotActive
      }
    }

    guard let session = decompressionSession else {
      throw VTDecoderError.sessionNotActive
    }

    // Create sample buffer
    let sample = try createSampleBuffer(from: data, pts: pts, dts: dts, duration: duration)

    // Decode synchronously using a pointer to capture output [Not fully supported with context yet in sync mode]
    // But for sync mode we don't usually have async metadata pipeline
    var outputPixelBuffer: CVPixelBuffer?
    let startTime = CFAbsoluteTimeGetCurrent()

    let status = withUnsafeMutablePointer(to: &outputPixelBuffer) { outputPtr in
      VTDecompressionSessionDecodeFrame(
        session,
        sampleBuffer: sample,
        flags: [],
        frameRefcon: outputPtr,
        infoFlagsOut: nil
      )
    }

    let decodeDuration = CFAbsoluteTimeGetCurrent() - startTime
    totalDecodeTime += decodeDuration
    decodeCount += 1

    guard status == noErr else {
      throw VTDecoderError.decodeFailed(status)
    }

    return outputPixelBuffer
  }

  // MARK: - Decoding (Async Pipeline)

  /// Sends a packet to the decoder for asynchronous decoding.
  /// Call popFrame to retrieve results.
  /// Sends a compressed packet to the decoder.
  public func sendPacket(
    data: Data, pts: Int64, dts: Int64, duration: Int64, ambientMetadata: Data? = nil
  ) throws {
    // Ensure we have a valid session
    if decompressionSession == nil {
      if formatDescription != nil {
        try createDecompressionSession()
      } else {
        throw VTDecoderError.sessionNotActive
      }
    }

    guard let session = decompressionSession else {
      throw VTDecoderError.sessionNotActive
    }

    // Create Sample Buffer
    let sample = try createSampleBuffer(from: data, pts: pts, dts: dts, duration: duration)

    // Create context for this frame
    let frameContext = VTFrameContext(ambientMetadata: ambientMetadata)
    let frameRefcon = Unmanaged.passRetained(frameContext).toOpaque()

    let status = VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sample,
      flags: [._EnableAsynchronousDecompression],
      frameRefcon: frameRefcon,
      infoFlagsOut: nil
    )

    // If calls fail immediately, we must release the context, but VT usually takes ownership if successful?
    // Actually: "The decompression session calls the output callback... The frameRefcon is passed to the callback."
    // If the function returns an error, the callback might NOT be called.
    if status != noErr {
      Unmanaged<VTFrameContext>.fromOpaque(frameRefcon).release()
    }

    guard status == noErr else {
      throw VTDecoderError.decodeFailed(status)
    }
  }

  // MARK: - Flush

  /// Flushes the decompression session and clears the frame queue.
  public func flush() {
    if let session = decompressionSession {
      VTDecompressionSessionFinishDelayedFrames(session)
      VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    queueLock.lock()
    frameQueue.removeAll()
    queueLock.unlock()
  }

  /// Waits for all submitted frames to be decoded.
  /// Unlike flush(), this does NOT clear the frame queue.
  public func finish() {
    if let session = decompressionSession {
      VTDecompressionSessionFinishDelayedFrames(session)
      VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
  }

  // MARK: - Helper Methods

  private func createSampleBuffer(from data: Data, pts: Int64, dts: Int64, duration: Int64) throws
    -> CMSampleBuffer
  {
    guard !data.isEmpty else {
      throw VTDecoderError.blockBufferCreationFailed(-1)
    }

    // Create CMBlockBuffer
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &blockBuffer
    )

    guard status == noErr, let block = blockBuffer else {
      throw VTDecoderError.blockBufferCreationFailed(status)
    }

    // Copy data into block buffer
    status = data.withUnsafeBytes { ptr in
      CMBlockBufferReplaceDataBytes(
        with: ptr.baseAddress!,
        blockBuffer: block,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }

    guard status == noErr else {
      throw VTDecoderError.blockBufferCreationFailed(status)
    }

    // Create timing info
    var timingInfo = CMSampleTimingInfo()
    if duration > 0 {
      timingInfo.duration = CMTime(value: duration * Int64(timeBaseNum), timescale: timeBaseDen)
    } else {
      timingInfo.duration = .invalid
    }
    timingInfo.presentationTimeStamp =
      pts != Int64.min ? CMTime(value: pts * Int64(timeBaseNum), timescale: timeBaseDen) : .invalid
    timingInfo.decodeTimeStamp =
      dts != Int64.min
      ? CMTime(value: dts * Int64(timeBaseNum), timescale: timeBaseDen)
      : timingInfo.presentationTimeStamp

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
      throw VTDecoderError.sampleBufferCreationFailed(status)
    }

    return sample
  }
}

// MARK: - Decompression Callback

private func decompressionOutputCallback(
  decompressionOutputRefCon: UnsafeMutableRawPointer?,
  sourceFrameRefCon: UnsafeMutableRawPointer?,
  status: OSStatus,
  infoFlags: VTDecodeInfoFlags,
  imageBuffer: CVImageBuffer?,
  presentationTimeStamp: CMTime,
  presentationDuration: CMTime
) {
  guard status == noErr, let pixelBuffer = imageBuffer else { return }

  guard let refCon = decompressionOutputRefCon else { return }
  let decoder = Unmanaged<VTDecoder>.fromOpaque(refCon).takeUnretainedValue()

  // Check if asynchronous mode
  if infoFlags.contains(.asynchronous) {
    let context: VTFrameContext? = sourceFrameRefCon.map {
      Unmanaged<VTFrameContext>.fromOpaque($0).takeRetainedValue()
    }

    // Handle ambient viewing environment debugging
    if let context = context {
      if let ambientData = context.ambientMetadata {
        CVBufferSetAttachment(
          pixelBuffer, kCVImageBufferAmbientViewingEnvironmentKey, ambientData as CFData,
          .shouldPropagate)
      }
    }

    // We passed the context as sourceFrameRefCon
    decoder.enqueueFrame(pixelBuffer, pts: presentationTimeStamp)
  } else {
    // Synchronous: sourceFrameRefCon is a pointer to a CVPixelBuffer? (stack address)
    if let outputPtr = sourceFrameRefCon {
      let bufferPtr = outputPtr.assumingMemoryBound(to: CVPixelBuffer?.self)
      // Swift ARC manages CVPixelBuffer, no explicit retain needed here as it's assigned to a strong variable on the stack
      bufferPtr.pointee = pixelBuffer
      // Metadata attachment for sync mode is handled by the caller (decodePacketSync)
    }
  }
}
