//
//  VideoDecoder.swift
//  VidCore
//
//  Swift async wrapper around FFmpegDecoder with separated demux/decode pipelines
//

import AVFoundation
import CoreVideo
import Foundation

/// Metadata about a video stream.
///
/// Contains information about the video dimensions, timing, codec, and hardware acceleration status.
/// This is available immediately after initializing a ``VideoDecoder``.
///
/// ## Example
/// ```swift
/// let decoder = try VideoDecoder(url: videoURL)
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
    /// Codec identifier (e.g., "h264", "vp9", "hevc").
    public let codecName: String
    /// Whether VideoToolbox hardware acceleration is active.
    public let isHardwareAccelerated: Bool
    /// Whether the video is HDR content (PQ or HLG transfer function).
    public let isHDR: Bool
    
    /// Specific decoder used (e.g. "VideoToolbox", "h264").
    public let decoderName: String?
    /// Description of the decoder implementation.
    public let decoderDescription: String?
    
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
    
    // MARK: - Computed Properties
    
    /// Human-readable transfer function name
    public var transferFunctionName: String {
        switch colorTransfer {
        case 1: return "BT.709"
        case 16: return isDolbyVision ? "PQ (DoVi)" : "PQ (HDR10)"
        case 18: return "HLG"
        default:
            // DoVi content may not have standard FFmpeg color metadata
            if isDolbyVision { return "PQ (DoVi)" }
            return colorTransfer > 0 ? "Unknown (\(colorTransfer))" : "Unspecified"
        }
    }
    
    /// Human-readable color primaries name
    public var colorPrimariesName: String {
        switch colorPrimaries {
        case 1: return "BT.709"
        case 9: return "BT.2020"
        default:
            // DoVi content is always BT.2020
            if isDolbyVision { return "BT.2020 (IPT)" }
            return colorPrimaries > 0 ? "Unknown (\(colorPrimaries))" : "Unspecified"
        }
    }
    
    /// Human-readable color space/matrix name
    public var colorSpaceName: String {
        // DoVi Profile 5 uses IPTPQc2 color space
        if isDolbyVision {
            return "IPTPQc2"
        }
        
        switch colorSpace {
        case 1: return "BT.709"
        case 5: return "BT.470bg"
        case 6: return "SMPTE 170M"
        case 9: return "BT.2020nc"
        case 10: return "BT.2020c"
        default: return colorSpace > 0 ? "Unspecified (\(colorSpace))" : "YCbCr"
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
        return 1000.0 // HDR10 default
    }
    
    public init(
        width: Int, height: Int, frameRate: Double, duration: Double, codecName: String,
        isHardwareAccelerated: Bool, isHDR: Bool = false,
        colorPrimaries: Int = 0, colorTransfer: Int = 0, colorSpace: Int = 0,
        colorRange: Int = 0, bitsPerComponent: Int = 8, isDolbyVision: Bool = false,
        maxContentLightLevel: UInt? = nil, maxFrameAverageLightLevel: UInt? = nil,
        masteringDisplayMaxLuminance: Float? = nil, masteringDisplayMinLuminance: Float? = nil,
        audioCodecName: String? = nil, audioSampleRate: Int? = nil, audioChannels: Int? = nil,
        decoderName: String? = nil, decoderDescription: String? = nil
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.duration = duration
        self.codecName = codecName
        self.isHardwareAccelerated = isHardwareAccelerated
        self.isHDR = isHDR
        self.colorPrimaries = colorPrimaries
        self.colorTransfer = colorTransfer
        self.colorSpace = colorSpace
        self.colorRange = colorRange
        self.bitsPerComponent = bitsPerComponent
        self.isDolbyVision = isDolbyVision
        self.maxContentLightLevel = maxContentLightLevel
        self.maxFrameAverageLightLevel = maxFrameAverageLightLevel
        self.masteringDisplayMaxLuminance = masteringDisplayMaxLuminance
        self.masteringDisplayMinLuminance = masteringDisplayMinLuminance
        self.audioCodecName = audioCodecName
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.decoderName = decoderName
        self.decoderDescription = decoderDescription
    }
}

/// A decoded frame from the video stream.
///
/// Each frame can be either video (a ``VideoFrame`` with pixel data) or audio (a PCM buffer with its presentation timestamp).
public enum DecodedFrame {
    /// A decoded video frame with pixel buffer and timing.
    case video(VideoFrame)
    /// An audio buffer with its presentation timestamp in seconds.
    case audio(AVAudioPCMBuffer, Double)
}

/// High-performance video decoder using FFmpeg with VideoToolbox hardware acceleration.
///
/// `VideoDecoder` wraps FFmpeg to provide async/await video decoding for macOS. It automatically
/// uses VideoToolbox hardware acceleration when available, falling back to optimized software decoding.
///
/// ## Features
/// - Supports MKV, WebM, AVI, MP4, and other container formats
/// - Hardware-accelerated decoding via VideoToolbox (H.264, H.265/HEVC)
/// - Software decoding for VP8, VP9, AV1, and other codecs
/// - Accurate frame-level seeking
/// - Parallel demux/decode pipeline for optimal performance
///
/// ## Example
/// ```swift
/// let decoder = try VideoDecoder(url: videoURL)
///
/// while let frame = try await decoder.decodeNextFrame() {
///     switch frame {
///     case .video(let videoFrame):
///         // Render via Metal
///     case .audio(let buffer, let pts):
///         // Play audio
///     }
/// }
///
/// decoder.close()
/// ```
public class VideoDecoder {
    private var decoder: FFmpegDecoder?
    private let url: URL

    // Separate queues for demuxing and decoding to enable parallelism
    private let demuxQueue = DispatchQueue(label: "com.vidpreview.demux", qos: .userInitiated)
    private let decodeQueue = DispatchQueue(
        label: "com.vidpreview.decode", qos: .userInitiated, attributes: .concurrent)

    private let lock = NSLock()
    private var isClosed = false

    /// Metadata about the video stream.
    public let videoInfo: VideoInfo

    /// Creates a new decoder for the specified video file.
    ///
    /// This initializes FFmpeg and opens the video file, automatically detecting the container
    /// format and selecting appropriate decoders. Hardware acceleration is enabled automatically
    /// when available.
    ///
    /// - Parameter url: The file URL of the video to decode.
    /// - Throws: An error if the file cannot be opened or contains no valid video stream.
    public init(url: URL) throws {
        self.url = url

        do {
            self.decoder = try FFmpegDecoder(url: url)
        } catch {
            throw error
        }

        guard let decoder = self.decoder, let info = decoder.getVideoInfo() else {
            throw NSError(
                domain: "VideoDecoder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get video info"])
        }

        self.videoInfo = VideoInfo(
            width: Int(info.width),
            height: Int(info.height),
            frameRate: info.frameRate,
            duration: info.duration,
            codecName: info.codecName,
            isHardwareAccelerated: info.isHardwareAccelerated,
            isHDR: info.isHDR,
            colorPrimaries: Int(info.colorPrimaries),
            colorTransfer: Int(info.colorTransfer),
            colorSpace: Int(info.colorSpace),
            colorRange: Int(info.colorRange),
            bitsPerComponent: Int(info.bitsPerComponent),
            isDolbyVision: info.isDolbyVision,
            maxContentLightLevel: info.maxContentLightLevel > 0 ? UInt(info.maxContentLightLevel) : nil,
            maxFrameAverageLightLevel: info.maxFrameAverageLightLevel > 0 ? UInt(info.maxFrameAverageLightLevel) : nil,
            masteringDisplayMaxLuminance: info.masteringDisplayMaxLuminance > 0 ? info.masteringDisplayMaxLuminance : nil,
            masteringDisplayMinLuminance: info.masteringDisplayMinLuminance > 0 ? info.masteringDisplayMinLuminance : nil,
            audioCodecName: info.audioCodecName,
            audioSampleRate: info.audioSampleRate > 0 ? Int(info.audioSampleRate) : nil,
            audioChannels: info.audioChannels > 0 ? Int(info.audioChannels) : nil,
            decoderName: info.decoderName,
            decoderDescription: info.decoderDescription
        )
    }

    deinit {
        print("[VideoDecoder] DEINIT - deallocating")
        close()
    }

    /// Closes the decoder safely, ensuring all pending operations complete
    public func close() {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed, let decoder = self.decoder else { return }
        isClosed = true
        decoder.close()
        self.decoder = nil
    }

    private var isDecoderClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    // MARK: - Parallel Demux/Decode API

    /// Demux next packet from the container (runs on demux queue)
    /// Returns nil at end of stream
    public func demuxNextPacket() async -> FFmpegPacketData? {
        return await withCheckedContinuation { continuation in
            demuxQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                self.lock.lock()
                defer { self.lock.unlock() }

                guard !self.isClosed, let decoder = self.decoder else {
                    continuation.resume(returning: nil)
                    return
                }

                let packet = decoder.demuxNextPacket()
                continuation.resume(returning: packet)
            }
        }
    }

    /// Decode a packet into frames (can run concurrently on decode queue)
    /// Returns array of decoded frames - may be multiple for video with multi-threaded decoding
    /// Returns empty array if packet produces no output (e.g., decoder needs more data)
    public func decodePacket(_ packet: FFmpegPacketData) async -> [DecodedFrame] {
        return await withCheckedContinuation { continuation in
            decodeQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }

                self.lock.lock()
                defer { self.lock.unlock() }

                guard !self.isClosed, let decoder = self.decoder else {
                    continuation.resume(returning: [])
                    return
                }

                var results: [DecodedFrame] = []

                if packet.isVideo {
                    if let ffmpegFrames = decoder.decodeVideoPacket(withAllFrames: packet) {
                        for ffmpegFrame in ffmpegFrames {
                            var doviMetadata: DoViMetadata? = nil
                            if let doviDict = ffmpegFrame.doviMetadata as? [String: Any] {
                                doviMetadata = DoViMetadata(fromDictionary: doviDict)
                            }
                            
                            let frame = VideoFrame(
                                pixelBuffer: ffmpegFrame.pixelBuffer,
                                presentationTime: ffmpegFrame.presentationTime,
                                isHDR: self.videoInfo.isHDR,
                                doviMetadata: doviMetadata,
                                colorTransfer: self.videoInfo.colorTransfer
                            )
                            results.append(.video(frame))
                        }
                    }
                }
                // Handle audio packets - typically 1:1 packet-to-frame
                else if packet.isAudio {
                    if let decodedFrame = decoder.decodePacket(packet),
                        let audioFrameObj = decodedFrame as? FFmpegAudioFrame
                    {
                        results.append(
                            .audio(audioFrameObj.pcmBuffer, audioFrameObj.presentationTime))
                    }
                }

                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - Decoder Flush/Drain (for multi-threaded decoders)

    /// Flush the video decoder to signal end of stream
    /// Must be called before draining remaining frames
    public func flushVideoDecoder() async {
        await withCheckedContinuation { continuation in
            decodeQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                self.lock.lock()
                defer { self.lock.unlock() }

                guard !self.isClosed, let decoder = self.decoder else {
                    continuation.resume()
                    return
                }

                decoder.flushVideoDecoder()
                continuation.resume()
            }
        }
    }

    /// Drain remaining buffered frames from the decoder after flush
    /// Returns nil when all frames have been drained
    public func drainVideoFrame() async -> VideoFrame? {
        return await withCheckedContinuation { continuation in
            decodeQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                self.lock.lock()
                defer { self.lock.unlock() }

                guard !self.isClosed, let decoder = self.decoder else {
                    continuation.resume(returning: nil)
                    return
                }

                guard let videoFrameObj = decoder.drainVideoFrame() else {
                    continuation.resume(returning: nil)
                    return
                }
                
                var doviMetadata: DoViMetadata? = nil
                if let doviDict = videoFrameObj.doviMetadata as? [String: Any] {
                    doviMetadata = DoViMetadata(fromDictionary: doviDict)
                }

                let frame = VideoFrame(
                    pixelBuffer: videoFrameObj.pixelBuffer,
                    presentationTime: videoFrameObj.presentationTime,
                    isHDR: self.videoInfo.isHDR,
                    doviMetadata: doviMetadata,
                    colorTransfer: self.videoInfo.colorTransfer
                )
                continuation.resume(returning: frame)
            }
        }
    }

    // MARK: - Cover Image Extraction

    /// Extracts an embedded cover image from the video container, if present.
    ///
    /// Many video containers (especially MKV) can include embedded cover art as attachment streams.
    /// This method searches for JPEG, PNG, or BMP attachments and returns the image data.
    ///
    /// - Returns: The cover image data, or nil if no cover image is found.
    public func extractCoverImage() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed, let decoder = self.decoder else { return nil }
        return decoder.extractCoverImage()
    }

    // MARK: - Seeking

    public func seek(to seconds: Double, accurate: Bool = true) async throws -> VideoFrame? {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<VideoFrame?, Error>) in
            demuxQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }

                self.lock.lock()
                defer { self.lock.unlock() }

                guard !self.isClosed, let decoder = self.decoder else {
                    continuation.resume(returning: nil)
                    return
                }

                if let ffmpegFrame = decoder.seek(toTime: seconds, accurate: accurate) {
                     var doviMetadata: DoViMetadata? = nil
                     if let doviDict = ffmpegFrame.doviMetadata as? [String: Any] {
                         doviMetadata = DoViMetadata(fromDictionary: doviDict)
                     }
                     
                     let frame = VideoFrame(
                         pixelBuffer: ffmpegFrame.pixelBuffer,
                         presentationTime: ffmpegFrame.presentationTime,
                         isHDR: self.videoInfo.isHDR,
                         doviMetadata: doviMetadata,
                         colorTransfer: self.videoInfo.colorTransfer
                     )
                     continuation.resume(returning: frame)
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "VideoDecoder", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Seek failed"]))
                }
            }
        }
    }
}
