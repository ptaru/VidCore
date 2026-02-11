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
        // Parse FFmpeg AVDOVIDecoderConfigurationRecord (first 8 bytes).

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

            // Reconstruct the dvcC atom for VideoToolbox.
            var dvcC = [UInt8](repeating: 0, count: 24)
            dvcC[0] = dvVersionMajor
            dvcC[1] = dvVersionMinor
            dvcC[2] = (dvProfile << 1) | ((dvLevel >> 5) & 0x01)
            dvcC[3] =
                ((dvLevel & 0x1F) << 3) | ((rpuPresentFlag & 0x01) << 2)
                | ((elPresentFlag & 0x01) << 1)
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
            extensions[kCVImageBufferYCbCrMatrixKey as String] =
                kCVImageBufferYCbCrMatrix_ITU_R_2020
        } else if config.colorSpace == 1 {  // BT.709
            extensions[kCVImageBufferYCbCrMatrixKey as String] =
                kCVImageBufferYCbCrMatrix_ITU_R_709_2
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

    private func applySampleAttachments(
        to sample: CMSampleBuffer,
        isKeyframe: Bool?,
        doNotDisplay: Bool
    ) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample, createIfNecessary: true) as? [NSMutableDictionary],
            let first = attachments.first
        else {
            return
        }

        if let isKeyframe {
            first[kCMSampleAttachmentKey_NotSync] =
                isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
            first[kCMSampleAttachmentKey_DependsOnOthers] =
                isKeyframe ? kCFBooleanFalse : kCFBooleanTrue
        }

        if doNotDisplay {
            first[kCMSampleAttachmentKey_DoNotDisplay] = kCFBooleanTrue
        } else {
            first.removeObject(forKey: kCMSampleAttachmentKey_DoNotDisplay)
        }
    }

    private func applySampleBufferAttachments(
        to sample: CMSampleBuffer,
        resetDecoderBeforeDecoding: Bool
    ) {
        guard resetDecoderBeforeDecoding else { return }
        CMSetAttachment(
            sample,
            key: kCMSampleBufferAttachmentKey_ResetDecoderBeforeDecoding,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldNotPropagate
        )
    }

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
        ambientLightMetadata: Data? = nil,
        isKeyframe: Bool? = nil,
        doNotDisplay: Bool = false,
        resetDecoderBeforeDecoding: Bool = false
    ) throws -> CMSampleBuffer {
        guard !data.isEmpty else {
            throw SampleBufferBuilderError.blockBufferCreationFailed(-1)
        }

        // Zero-copy: allocate once, copy once, hand ownership to CMBlockBuffer.

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

        // Wrap malloc'd memory; kCFAllocatorMalloc frees when released.
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
            timingInfo.duration = CMTime(
                value: duration * Int64(timeBaseNum), timescale: timeBaseDen)
        } else {
            timingInfo.duration = .invalid
        }

        // Presentation Time Stamp (PTS)
        timingInfo.presentationTimeStamp =
            pts != Int64.min
            ? CMTime(value: pts * Int64(timeBaseNum), timescale: timeBaseDen) : .invalid

        // AVSampleBufferDisplayLayer requires strictly monotonic DTS.

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
            // Enforce monotonic DTS.
            if lastDecodeStartTime.isValid {
                if !inputDTS.isValid || inputDTS <= lastDecodeStartTime {
                    // Synthesize from last DTS + duration (or 1 tick).
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
                timingInfo.decodeTimeStamp =
                    inputDTS.isValid ? inputDTS : timingInfo.presentationTimeStamp
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

        applySampleAttachments(
            to: sample,
            isKeyframe: isKeyframe,
            doNotDisplay: doNotDisplay
        )
        applySampleBufferAttachments(
            to: sample,
            resetDecoderBeforeDecoding: resetDecoderBeforeDecoding
        )

        return sample
    }
}
