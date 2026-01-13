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

    public init(
        width: Int, height: Int, frameRate: Double, duration: Double, codecName: String,
        isHardwareAccelerated: Bool, isHDR: Bool = false
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.duration = duration
        self.codecName = codecName
        self.isHardwareAccelerated = isHardwareAccelerated
        self.isHDR = isHDR
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
            isHDR: info.isHDR
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

    // MARK: - New Parallel Demux/Decode API

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

                // Handle video packets - get ALL available frames
                if packet.isVideo {
                    if let ffmpegFrames = decoder.decodeVideoPacket(withAllFrames: packet) {
                        for ffmpegFrame in ffmpegFrames {
                            let frame = VideoFrame(
                                pixelBuffer: ffmpegFrame.pixelBuffer,
                                presentationTime: ffmpegFrame.presentationTime,
                                isHDR: self.videoInfo.isHDR
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

                let frame = VideoFrame(
                    pixelBuffer: videoFrameObj.pixelBuffer,
                    presentationTime: videoFrameObj.presentationTime,
                    isHDR: self.videoInfo.isHDR
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

    public func seek(to seconds: Double, accurate: Bool = true) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            demuxQueue.async { [weak self] in
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

                let success = decoder.seek(toTime: seconds, accurate: accurate)

                if success {
                    continuation.resume()
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
