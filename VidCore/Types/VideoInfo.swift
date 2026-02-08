//
//  VideoInfo.swift
//  VidCore
//
//  Metadata about a video stream.
//

import Foundation

/// Metadata about a video stream.
///
/// Contains information about the video dimensions, timing, codec, and hardware acceleration status.
/// This is available immediately after initializing a ``MediaDecoder``.
///
/// ## Example
/// ```swift
/// let decoder = try MediaDecoder(url: videoURL)
/// print("Resolution: \(decoder.videoInfo.width)x\(decoder.videoInfo.height)")
/// print("Duration: \(decoder.videoInfo.duration) seconds")
/// ```
public struct VideoInfo {
  /// Video width in pixels.
  public let width: Int
  /// Video height in pixels.
  public let height: Int
  /// Frame rate in frames per second.
  public let frameRate: Double
  /// Total duration in seconds.
  public let duration: Double
  /// Container format name (e.g., "QuickTime / MOV", "Matroska / WebM").
  public let containerName: String
  /// Codec identifier (e.g., "h264", "vp9", "hevc").
  public let codecName: String
  /// Whether passthrough sample buffers are active (hardware rendering path).
  public let isHardwareAccelerated: Bool
  /// Whether the video is HDR content (PQ or HLG transfer function).
  public let isHDR: Bool

  /// Sample Aspect Ratio numerator (SAR num).
  public let sampleAspectRatioNum: Int
  /// Sample Aspect Ratio denominator (SAR den).
  public let sampleAspectRatioDen: Int

  /// Specific decoder used (e.g. "SampleBufferBuilder", "h264").
  public let decoderName: String?
  /// Description of the decoder implementation.
  public let decoderDescription: String?

  /// Whether extradata was manually synthesized from the bitstream.
  public let didSynthesizeExtradata: Bool

  // MARK: - Color Metadata

  /// Color primaries (FFmpeg AVCOL_PRI_*: 1=BT.709, 9=BT.2020).
  public let colorPrimaries: Int
  /// Transfer characteristics (FFmpeg AVCOL_TRC_*: 1=BT.709, 16=PQ, 18=HLG).
  public let colorTransfer: Int
  /// Color space/matrix (FFmpeg AVCOL_SPC_*: 1=BT.709, 9=BT.2020nc).
  public let colorSpace: Int
  /// Color range (FFmpeg AVCOL_RANGE_*: 1=limited, 2=full).
  public let colorRange: Int
  /// Bits per color component (8, 10, 12).
  public let bitsPerComponent: Int
  /// Whether the content is Dolby Vision.
  public let isDolbyVision: Bool
  /// Dolby Vision Profile ID (e.g. 5, 7, 8), nil if not Dolby Vision.
  public let doviProfile: Int?

  // MARK: - HDR Static Metadata

  /// Maximum Content Light Level in nits (MaxCLL), nil if not present in metadata.
  public let maxContentLightLevel: UInt?
  /// Maximum Frame-Average Light Level in nits (MaxFALL), nil if not present.
  public let maxFrameAverageLightLevel: UInt?
  /// Mastering display maximum luminance in nits, nil if not present.
  public let masteringDisplayMaxLuminance: Float?
  /// Mastering display minimum luminance in nits, nil if not present.
  public let masteringDisplayMinLuminance: Float?

  // MARK: - Audio Info

  /// Audio codec name (e.g., "aac", "opus", "flac"), nil if no audio.
  public let audioCodecName: String?
  /// Audio sample rate in Hz (e.g., 48000), nil if no audio.
  public let audioSampleRate: Int?
  /// Number of audio channels (e.g., 2 for stereo), nil if no audio.
  public let audioChannels: Int?
  /// All available audio tracks in the container.
  public let audioTracks: [AudioTrackInfo]

  // MARK: - Subtitle Info

  /// All available subtitle tracks in the container.
  public let subtitleTracks: [SubtitleTrackInfo]

  // MARK: - Computed Properties

  /// Human-readable transfer function name
  public var transferFunctionName: String {
    switch colorTransfer {
    case 1: return "BT.709"
    case 16: return "PQ"
    case 18: return "HLG"
    default:
      return colorTransfer > 0 ? "Unknown" : "Unspecified"
    }
  }

  /// Human-readable color primaries name
  public var colorPrimariesName: String {
    switch colorPrimaries {
    case 1: return "BT.709"
    case 9: return "BT.2020"
    default:
      return colorPrimaries > 0 ? "Unknown" : "Unspecified"
    }
  }

  /// Human-readable color space/matrix name
  public var colorSpaceName: String {
    switch colorSpace {
    case 1: return "BT.709"
    case 5: return "BT.470bg"
    case 6: return "SMPTE 170M"
    case 9: return "BT.2020nc"
    case 10: return "BT.2020c"
    default: return colorSpace > 0 ? "Unspecified" : "YCbCr"
    }
  }

  /// The recommended content peak nits for HDR tone mapping.
  ///
  /// Uses MaxCLL if available, falls back to mastering display max luminance,
  /// then defaults to 1000 nits (standard HDR10).
  public var contentPeakNits: Float {
    if let maxCLL = maxContentLightLevel, maxCLL > 0 {
      return Float(maxCLL)
    }
    if let mdMax = masteringDisplayMaxLuminance, mdMax > 0 {
      return mdMax
    }
    return 1000.0  // HDR10 default
  }

  /// The intended display aspect ratio.
  public var displayAspectRatio: Double {
    let sar =
      (sampleAspectRatioNum > 0 && sampleAspectRatioDen > 0)
      ? Double(sampleAspectRatioNum) / Double(sampleAspectRatioDen) : 1.0
    return (Double(width) / Double(height)) * sar
  }

  /// Creates a new video info structure.
  /// - Parameters:
  ///   - width: Video width in pixels.
  ///   - height: Video height in pixels.
  ///   - frameRate: Frame rate in FPS.
  ///   - duration: Total duration in seconds.
  ///   - containerName: Container format name.
  ///   - codecName: Codec identifier.
  ///   - isHardwareAccelerated: Whether hardware acceleration is used.
  ///   - isHDR: Whether content is HDR.
  ///   - colorPrimaries: Color primaries ID.
  ///   - colorTransfer: Color transfer characteristic ID.
  ///   - colorSpace: Color space/matrix ID.
  ///   - colorRange: Color range ID.
  ///   - bitsPerComponent: Bits per color component.
  ///   - isDolbyVision: Whether content is Dolby Vision.
  ///   - doviProfile: Dolby Vision profile ID.
  ///   - maxContentLightLevel: MaxCLL in nits.
  ///   - maxFrameAverageLightLevel: MaxFALL in nits.
  ///   - masteringDisplayMaxLuminance: Mastering display max luminance in nits.
  ///   - masteringDisplayMinLuminance: Mastering display min luminance in nits.
  ///   - audioCodecName: Audio codec name.
  ///   - audioSampleRate: Audio sample rate in Hz.
  ///   - audioChannels: Number of audio channels.
  ///   - audioTracks: All available audio tracks.
  ///   - subtitleTracks: All available subtitle tracks.
  ///   - sampleAspectRatioNum: SAR numerator.
  ///   - sampleAspectRatioDen: SAR denominator.
  ///   - decoderName: Name of the decoder used.
  ///   - decoderDescription: Description of the decoder.
  ///   - didSynthesizeExtradata: Whether extradata was synthesized.
  public init(
    width: Int, height: Int, frameRate: Double, duration: Double, containerName: String,
    codecName: String,
    isHardwareAccelerated: Bool, isHDR: Bool = false,
    colorPrimaries: Int = 0, colorTransfer: Int = 0, colorSpace: Int = 0,
    colorRange: Int = 0, bitsPerComponent: Int = 8, isDolbyVision: Bool = false,
    doviProfile: Int? = nil,
    maxContentLightLevel: UInt? = nil, maxFrameAverageLightLevel: UInt? = nil,
    masteringDisplayMaxLuminance: Float? = nil, masteringDisplayMinLuminance: Float? = nil,
    audioCodecName: String? = nil, audioSampleRate: Int? = nil, audioChannels: Int? = nil,
    audioTracks: [AudioTrackInfo] = [],
    subtitleTracks: [SubtitleTrackInfo] = [],
    sampleAspectRatioNum: Int = 1,
    sampleAspectRatioDen: Int = 1,
    decoderName: String? = nil,
    decoderDescription: String? = nil,
    didSynthesizeExtradata: Bool = false
  ) {
    self.width = width
    self.height = height
    self.frameRate = frameRate
    self.duration = duration
    self.containerName = containerName
    self.codecName = codecName
    self.isHardwareAccelerated = isHardwareAccelerated
    self.isHDR = isHDR
    self.colorPrimaries = colorPrimaries
    self.colorTransfer = colorTransfer
    self.colorSpace = colorSpace
    self.colorRange = colorRange
    self.bitsPerComponent = bitsPerComponent
    self.isDolbyVision = isDolbyVision
    self.doviProfile = doviProfile
    self.maxContentLightLevel = maxContentLightLevel
    self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
    self.masteringDisplayMaxLuminance = masteringDisplayMaxLuminance
    self.masteringDisplayMinLuminance = masteringDisplayMinLuminance
    self.audioCodecName = audioCodecName
    self.audioSampleRate = audioSampleRate
    self.audioChannels = audioChannels
    self.audioTracks = audioTracks
    self.subtitleTracks = subtitleTracks
    self.sampleAspectRatioNum = sampleAspectRatioNum
    self.sampleAspectRatioDen = sampleAspectRatioDen
    self.decoderName = decoderName
    self.decoderDescription = decoderDescription
    self.didSynthesizeExtradata = didSynthesizeExtradata
  }
}
