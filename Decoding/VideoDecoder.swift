//
//  VideoDecoder.swift
//  VidCore
//
//  High-performance video decoder orchestrating FFmpeg and VideoToolbox with async pipelines
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

extension FFmpegPacketData: @unchecked Sendable {}


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
    /// Container format name (e.g., "QuickTime / MOV", "Matroska / WebM").
    public let containerName: String
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
        return 1000.0 // HDR10 default
    }
    
    public init(
        width: Int, height: Int, frameRate: Double, duration: Double, containerName: String, codecName: String,
        isHardwareAccelerated: Bool, isHDR: Bool = false,
        colorPrimaries: Int = 0, colorTransfer: Int = 0, colorSpace: Int = 0,
        colorRange: Int = 0, bitsPerComponent: Int = 8, isDolbyVision: Bool = false, doviProfile: Int? = nil,
        maxContentLightLevel: UInt? = nil, maxFrameAverageLightLevel: UInt? = nil,
        masteringDisplayMaxLuminance: Float? = nil, masteringDisplayMinLuminance: Float? = nil,
        audioCodecName: String? = nil, audioSampleRate: Int? = nil, audioChannels: Int? = nil,
        decoderName: String? = nil, decoderDescription: String? = nil,
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
        self.decoderName = decoderName
        self.decoderDescription = decoderDescription
        self.didSynthesizeExtradata = didSynthesizeExtradata
    }
}

// MARK: - VTDecoder Config Bridging

/// Convert FFmpegDecoder's config dictionary to Swift VTDecoderConfig
private func createVTDecoder(from config: [String: Any]) throws -> VTDecoder {
    guard let codecNum = config["codec"] as? NSNumber,
          let width = config["width"] as? NSNumber,
          let height = config["height"] as? NSNumber,
          let extradata = config["extradata"] as? Data,
          let timeBaseNum = config["timeBaseNum"] as? NSNumber,
          let timeBaseDen = config["timeBaseDen"] as? NSNumber else {
        throw VTDecoderError.noExtradata
    }
    
    let codec: VTDecoderCodec = codecNum.intValue == 0 ? .hevc : .h264
    
    let vtConfig = VTDecoderConfig(
        codec: codec,
        width: width.int32Value,
        height: height.int32Value,
        extradata: extradata,
        timeBaseNum: timeBaseNum.int32Value,
        timeBaseDen: timeBaseDen.int32Value,
        colorPrimaries: (config["colorPrimaries"] as? NSNumber)?.int32Value ?? 0,
        colorTransfer: (config["colorTransfer"] as? NSNumber)?.int32Value ?? 0,
        colorSpace: (config["colorSpace"] as? NSNumber)?.int32Value ?? 0,
        dolbyVisionConfig: config["dolbyVisionConfig"] as? Data
    )
    
    return try VTDecoder(config: vtConfig)
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
public final class VideoDecoder: @unchecked Sendable {
    private var demuxer: FFmpegDemuxer?
    private var decoder: FFmpegDecoder?
    private var vtDecoder: VTDecoder?
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

        // Phase 1: Create FFmpegDemuxer for container I/O
        do {
            self.demuxer = try FFmpegDemuxer(url: url)
        } catch {
            throw error
        }

        guard let demuxer = self.demuxer, let info = demuxer.getVideoInfo() else {
            throw NSError(
                domain: "VideoDecoder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get video info"])
        }

        // Phase 2: Try to initialize Swift VTDecoder for supported codecs (HEVC/H264)
        var finalDecoderName = info.codecName
        var finalDecoderDescription = "Unknown"
        var finalIsHardwareAccelerated = false
        
        if let vtConfig = demuxer.getVTDecoderConfig() {
            do {
                self.vtDecoder = try createVTDecoder(from: vtConfig)
                if let vt = self.vtDecoder {
                    print("[VideoDecoder] Using Swift VTDecoder (DoVi: \(vt.isDolbyVision), profile: \(vt.dolbyVisionProfile))")
                    if vt.isDolbyVision {
                        finalDecoderName = "VTDecoder (DoVi P\(vt.dolbyVisionProfile))"
                    } else {
                        finalDecoderName = "VTDecoder (\(info.codecName))"
                    }
                    finalDecoderDescription = "Hardware Acceleration (Swift VTDecoder)"
                    finalIsHardwareAccelerated = true
                }
            } catch {
                print("[VideoDecoder] Failed to init VTDecoder: \(error)")
                self.vtDecoder = nil
            }
        }
        
        // Phase 3: Initialize FFmpegDecoder in decode-only mode (fallback for audio + unsupported codecs)
        if let decoderConfig = demuxer.getDecoderConfig() {
            do {
                self.decoder = try FFmpegDecoder(demuxerConfig: decoderConfig)
                if self.vtDecoder == nil, let decoder = self.decoder, let decoderInfo = decoder.getVideoInfo() {
                    // No VTDecoder, use FFmpegDecoder info
                    finalDecoderName = decoderInfo.decoderName
                    finalDecoderDescription = decoderInfo.decoderDescription
                    finalIsHardwareAccelerated = decoderInfo.isHardwareAccelerated
                }
            } catch {
                print("[VideoDecoder] Failed to init FFmpegDecoder: \(error)")
                // If we have VTDecoder, we can still proceed for video-only
                if self.vtDecoder == nil {
                    throw error
                }
            }
        }
        
        // Create final videoInfo
        self.videoInfo = VideoInfo(
            width: Int(info.width),
            height: Int(info.height),
            frameRate: info.frameRate,
            duration: info.duration,
            containerName: info.formatName,
            codecName: info.codecName,
            isHardwareAccelerated: finalIsHardwareAccelerated,
            isHDR: info.isHDR,
            colorPrimaries: Int(info.colorPrimaries),
            colorTransfer: Int(info.colorTransfer),
            colorSpace: Int(info.colorSpace),
            colorRange: Int(info.colorRange),
            bitsPerComponent: Int(info.bitsPerComponent),
            isDolbyVision: info.isDolbyVision,
            doviProfile: info.isDolbyVision ? Int(info.doviProfile) : nil,
            maxContentLightLevel: info.maxContentLightLevel > 0 ? UInt(info.maxContentLightLevel) : nil,
            maxFrameAverageLightLevel: info.maxFrameAverageLightLevel > 0 ? UInt(info.maxFrameAverageLightLevel) : nil,
            masteringDisplayMaxLuminance: info.masteringDisplayMaxLuminance > 0 ? Float(info.masteringDisplayMaxLuminance) : nil,
            masteringDisplayMinLuminance: info.masteringDisplayMinLuminance > 0 ? Float(info.masteringDisplayMinLuminance) : nil,
            audioCodecName: info.audioCodecName,
            audioSampleRate: info.audioSampleRate > 0 ? Int(info.audioSampleRate) : nil,
            audioChannels: info.audioChannels > 0 ? Int(info.audioChannels) : nil,
            decoderName: finalDecoderName,
            decoderDescription: finalDecoderDescription,
            didSynthesizeExtradata: demuxer.didSynthesizeExtradata
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

        guard !isClosed else { return }
        isClosed = true
        
        // Flush VTDecoder if used
        vtDecoder?.flush()
        vtDecoder = nil
        
        // Close FFmpegDecoder
        decoder?.close()
        decoder = nil
        
        // Close FFmpegDemuxer
        demuxer?.close()
        demuxer = nil
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

                guard !self.isClosed, let demuxer = self.demuxer else {
                    continuation.resume(returning: nil)
                    return
                }

                // Demux using FFmpegDemuxer and convert to FFmpegPacketData
                if let demuxerPacket = demuxer.demuxNextPacket() {
                    let packet = self.convertPacket(demuxerPacket)
                    continuation.resume(returning: packet)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Convert FFmpegDemuxerPacket to FFmpegPacketData for API compatibility
    private func convertPacket(_ demuxerPacket: FFmpegDemuxerPacket) -> FFmpegPacketData {
        let packet = FFmpegPacketData()
        packet.data = demuxerPacket.data
        packet.size = Int32(truncatingIfNeeded: demuxerPacket.size)
        packet.pts = demuxerPacket.pts
        packet.dts = demuxerPacket.dts
        packet.duration = demuxerPacket.duration
        packet.isVideo = demuxerPacket.isVideo
        packet.isAudio = demuxerPacket.isAudio
        packet.flags = demuxerPacket.isKeyframe ? 1 : 0 // AV_PKT_FLAG_KEY = 1
        packet.ambientLightMetadata = demuxerPacket.ambientLightMetadata
        return packet
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
                    // Use Swift VTDecoder if available
                    if let vtDecoder = self.vtDecoder {
                        do {
                                try vtDecoder.sendPacket(
                                    data: packet.data,
                                    pts: packet.pts,
                                    dts: packet.dts,
                                    duration: packet.duration,
                                    ambientMetadata: packet.ambientLightMetadata
                                )
                                
                                // Pop all available frames
                                while let decodedFrame = vtDecoder.popFrame() {
                                    let pts = CMTimeGetSeconds(decodedFrame.presentationTime)
                                    let doviProfile = vtDecoder.isDolbyVision ? Int(vtDecoder.dolbyVisionProfile) : 0
                                    let frame = self.makeVideoFrame(
                                        pixelBuffer: decodedFrame.pixelBuffer,
                                        presentationTime: pts,
                                        doviProfile: doviProfile
                                    )
                                    results.append(.video(frame))
                                }
                        } catch {
                            print("[VideoDecoder] VTDecoder error: \(error)")
                        }
                    } else if let ffmpegFrames = decoder.decodeVideoPacket(withAllFrames: packet) {
                        // Fallback to FFmpeg decode path
                        for ffmpegFrame in ffmpegFrames {

                            let frame = self.makeVideoFrame(
                                pixelBuffer: ffmpegFrame.pixelBuffer,
                                presentationTime: ffmpegFrame.presentationTime,
                                doviProfile: Int(ffmpegFrame.doviProfile)
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


                let frame = self.makeVideoFrame(
                    pixelBuffer: videoFrameObj.pixelBuffer,
                    presentationTime: videoFrameObj.presentationTime,
                    doviProfile: Int(videoFrameObj.doviProfile)
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

        guard !isClosed, let demuxer = self.demuxer else { return nil }
        return demuxer.extractCoverImage()
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

                guard !self.isClosed else {
                    continuation.resume(returning: nil)
                    return
                }
                
                // CRITICAL: Flush VTDecoder before seeking to clear any pending frames
                // This prevents audio/video desync after seek
                self.vtDecoder?.flush()
                
                // Dispatch based on available decoder
                if self.vtDecoder != nil {
                    do {
                        let frame = try self.seekVTDecoder(to: seconds, accurate: accurate)
                        continuation.resume(returning: frame)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else if self.decoder != nil {
                    do {
                         let frame = try self.seekFFmpeg(to: seconds, accurate: accurate)
                         continuation.resume(returning: frame)
                    } catch {
                         continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "VideoDecoder", code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "Seek failed - decoder unavailable"]))
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func makeVideoFrame(
        pixelBuffer: CVPixelBuffer,
        presentationTime: Double,
        doviProfile: Int
    ) -> VideoFrame {
        return VideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            isHDR: self.videoInfo.isHDR,
            colorTransfer: self.videoInfo.colorTransfer,
            doviProfile: doviProfile
        )
    }

    private func seekVTDecoder(to seconds: Double, accurate: Bool) throws -> VideoFrame? {
        guard let demuxer = self.demuxer, let vtDecoder = self.vtDecoder else { return nil }
        
        // VTDecoder path: use demuxer for seeking and getting packets
        // Then decode through VTDecoder for correct Dolby Vision colors
        guard demuxer.seek(toKeyframe: seconds) else {
            throw NSError(
                domain: "VideoDecoder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Seek failed - seek error"])
        }
        
        // Collect packets from demuxer
        var packets: [FFmpegDemuxerPacket] = []
        if accurate {
            if let collectedPackets = demuxer.collectPackets(until: seconds) {
                packets = collectedPackets
            }
        } else {
            if let keyframePackets = demuxer.collectKeyframePackets() {
                packets = keyframePackets
            }
        }
        
        guard !packets.isEmpty else {
            throw NSError(
                domain: "VideoDecoder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Seek failed - no packets"])
        }
        
        // Decode packets through VTDecoder
        var lastFrame: VTDecodedFrame?
        
        if !accurate && packets.count == 1 {
            // For non-accurate seek (single keyframe), use SYNCHRONOUS decoding
            // This ensures we get a frame immediately for responsiveness during scrubbing
            let packet = packets[0]
            do {
                if let pixelBuffer = try vtDecoder.decodePacketSync(
                    data: packet.data,
                    pts: packet.pts,
                    dts: packet.dts,
                    duration: packet.duration
                ) {
                    let pts = CMTime(value: packet.pts * Int64(vtDecoder.timeBaseNum),
                                     timescale: vtDecoder.timeBaseDen)
                    lastFrame = VTDecodedFrame(pixelBuffer: pixelBuffer, presentationTime: pts)
                }
            } catch {
                print("[VideoDecoder] VTDecoder sync decode error: \(error)")
            }
        } else {
            // For accurate seek (multiple packets), use async pipeline
            for packet in packets {
                do {
                    try vtDecoder.sendPacket(
                        data: packet.data,
                        pts: packet.pts,
                        dts: packet.dts,
                        duration: packet.duration
                    )
                    
                    // Pop all available frames, keep the last one at or after target
                    while let frame = vtDecoder.popFrame() {
                        let framePTS = CMTimeGetSeconds(frame.presentationTime)
                        if framePTS >= seconds - 0.01 {
                            lastFrame = frame
                        } else {
                            // Haven't reached target yet, keep this as backup
                            lastFrame = frame
                        }
                    }
                } catch {
                    print("[VideoDecoder] VTDecoder seek error: \(error)")
                }
            }
        }
        
        // Return the result frame
        if let resultFrame = lastFrame {
            let doviProfile = vtDecoder.isDolbyVision ? Int(vtDecoder.dolbyVisionProfile) : 0
            return self.makeVideoFrame(
                pixelBuffer: resultFrame.pixelBuffer,
                presentationTime: CMTimeGetSeconds(resultFrame.presentationTime),
                doviProfile: doviProfile
            )
        } else {
            throw NSError(
                domain: "VideoDecoder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Seek failed - no frame decoded"])
        }
    }

    private func seekFFmpeg(to seconds: Double, accurate: Bool) throws -> VideoFrame? {
        guard let demuxer = self.demuxer, let decoder = self.decoder else { return nil }
        
        // Non-VTDecoder path: use demuxer to seek, decoder to decode
        
        // Flush decoder buffers to clear state (fix for replay issues)
        decoder.flushCodecBuffers()
        
        guard demuxer.seek(toKeyframe: seconds) else {
            throw NSError(
                domain: "VideoDecoder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Seek failed"])
        }
        
        // Robust Seek Loop: Feed packets until we get a frame
        var foundFrame: VideoFrame? = nil
        var packetCount = 0
        let maxPackets = 200 // Safety break
        
        while packetCount < maxPackets {
            let shouldStop = autoreleasepool { () -> Bool in
                // Read next packet directly
                guard let demuxerPacket = demuxer.demuxNextPacket() else {
                    return true // EOF
                }
                
                // Filter for video packets
                if demuxerPacket.isVideo {
                    packetCount += 1
                    let packet = self.convertPacket(demuxerPacket)
                    
                    if let ffmpegFrames = decoder.decodeVideoPacket(withAllFrames: packet) {
                        for ffmpegFrame in ffmpegFrames {
                            let framePTS = ffmpegFrame.presentationTime
                            
                            // For accurate seek: wait for target
                            // For fast seek: take first frame (keyframe or first available)
                            if framePTS >= seconds - 0.05 || !accurate {
                                let frame = self.makeVideoFrame(
                                    pixelBuffer: ffmpegFrame.pixelBuffer,
                                    presentationTime: framePTS,
                                    doviProfile: Int(ffmpegFrame.doviProfile)
                                )
                                foundFrame = frame
                                return true
                            }
                        }
                    }
                }
                return false
            }
            
            if shouldStop {
                break
            }
        }
        
        if let frame = foundFrame {
            return frame
        } else {
             throw NSError(
                domain: "VideoDecoder", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Seek failed - no suitable frame found"])
        }
    }
}