//
//  VideoDecoder.swift
//  VidCore
//
//  High-performance video decoder orchestrating FFmpeg and hardware passthrough
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

extension FFmpegPacketData: @unchecked Sendable {}

/// High-performance video decoder using FFmpeg with passthrough hardware rendering when available.
///
/// `VideoDecoder` wraps FFmpeg to provide async/await video decoding for macOS. It can build
/// passthrough sample buffers for AVSampleBufferDisplayLayer on supported codecs, falling back to
/// optimized software decoding when passthrough isn't available.
///
/// ## Features
/// - Supports MKV, WebM, AVI, MP4, and other container formats
/// - Hardware-accelerated rendering (H.264, H.265/HEVC)
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
///         // Render video frame
///     case .audio(let buffer, let pts):
///         // Play audio
///     }
/// }
///
/// decoder.close()
/// ```
public final class VideoDecoder: @unchecked Sendable {

  /// Modes for hardware acceleration
  public enum HardwareDecodeMode {
    /// Fully decode frames to CVPixelBuffers (standard behavior)
    case decode
    /// Wrap compressed samples in CMSampleBuffer for direct rendering by AVSBDL
    case passThrough
  }

  var demuxer: FFmpegDemuxer?
  var decoder: FFmpegDecoder?
  var sampleBufferBuilder: SampleBufferBuilder?

  let assPipeline: ASSSubtitlePipeline

  /// Renderer for ASS/SSA subtitles
  public var assRenderer: LibASSRenderer? {
    assPipeline.renderer
  }

  private let url: URL

  /// Current hardware decode mode
  public let hardwareDecodeMode: HardwareDecodeMode

  // Separate queues for demuxing and decoding to enable parallelism
  let demuxQueue = DispatchQueue(label: "com.vidpreview.demux", qos: .userInitiated)
  let decodeQueue = DispatchQueue(
    label: "com.vidpreview.decode", qos: .userInitiated, attributes: .concurrent)

  let lock = NSLock()
  var isClosed = false

  // Queue for packets needed to restore decoder context after a seek (Keyframe...Target)
  // These are re-emitted via demuxNextPacket to ensure the renderer gets the full GOP
  var pendingContextRestorationPackets: [FFmpegDemuxerPacket] = []

  /// Metadata about the video stream.
  public let videoInfo: VideoInfo

  // Logging removed for production performance

  // MARK: - Static Helpers

  /// Pre-detects whether hardware acceleration will be used for the given URL.
  ///
  /// This method performs a lightweight check to determine if passthrough is available
  /// for the video codec, without fully initializing the decoder. It's useful for
  /// pre-configuring buffer sizes before creating a VideoPlayer.
  ///
  /// - Parameter url: The URL of the video file to check
  /// - Returns: `true` if hardware acceleration will be used, `false` for software decoding
  public static func willUseHardwareAcceleration(for url: URL) -> Bool {
    do {
      let demuxer = try FFmpegDemuxer(url: url)
      defer { demuxer.close() }
      let config = demuxer.getSampleBufferBuilderConfig()
      return config != nil
    } catch {
      return false
    }
  }

  /// Creates a new decoder for the specified video file.
  ///
  /// This initializes FFmpeg and opens the video file, automatically detecting the container
  /// format and selecting appropriate decoders. Hardware acceleration is enabled automatically
  /// when available.
  ///
  /// - Parameter url: The file URL of the video to decode.
  /// - Parameter hardwareDecodeMode: Mode to set if we should decode or pass through. Defaults to .decode.
  /// - Throws: An error if the file cannot be opened or contains no valid video stream.
  public init(url: URL, hardwareDecodeMode: HardwareDecodeMode = .decode) throws {
    self.url = url
    self.hardwareDecodeMode = hardwareDecodeMode
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

    // Phase 2: Try to initialize SampleBufferBuilder for supported codecs (HEVC/H264)
    var finalDecoderName = info.codecName
    var finalDecoderDescription = "Unknown"
    var finalIsHardwareAccelerated = false

    if hardwareDecodeMode == .passThrough,
      let sbConfig = demuxer.getSampleBufferBuilderConfig()
    {
      do {
        self.sampleBufferBuilder = try createSampleBufferBuilder(from: sbConfig)
        if let builder = self.sampleBufferBuilder {
          if builder.isDolbyVision {
            finalDecoderName = "HW Passthrough (DoVi P\(builder.dolbyVisionProfile))"
          } else {
            finalDecoderName = "HW Passthrough (\(info.codecName))"
          }
          finalDecoderDescription = "Hardware Passthrough"
          finalIsHardwareAccelerated = true
        }
      } catch {
        self.sampleBufferBuilder = nil
      }
    }

    // Phase 3: Initialize FFmpegDecoder in decode-only mode (fallback for audio + unsupported codecs)
    if let decoderConfig = demuxer.getDecoderConfig() {
      do {
        self.decoder = try FFmpegDecoder(demuxerConfig: decoderConfig)
        if self.sampleBufferBuilder == nil, let decoder = self.decoder,
          let decoderInfo = decoder.getVideoInfo()
        {
          // No SampleBufferBuilder, use FFmpegDecoder info
          finalDecoderName = decoderInfo.decoderName
          finalDecoderDescription = decoderInfo.decoderDescription
          finalIsHardwareAccelerated = decoderInfo.isHardwareAccelerated
        }
      } catch {
        // If we have SampleBufferBuilder, we can still proceed for video-only
        if self.sampleBufferBuilder == nil {
          throw error
        }
      }
    }

    // Convert audio tracks from FFmpeg
    let audioTracks: [AudioTrackInfo] =
      demuxer.getAudioTracks()?.map { track in
        AudioTrackInfo(
          streamIndex: Int(track.streamIndex),
          language: track.language,
          title: track.title,
          codecName: track.codecName,
          sampleRate: Int(track.sampleRate),
          channels: Int(track.channels),
          isDefault: track.isDefault
        )
      } ?? []

    // Convert subtitle tracks from FFmpeg
    let subtitleTracks: [SubtitleTrackInfo] =
      demuxer.getSubtitleTracks()?.map { track in
        SubtitleTrackInfo(
          streamIndex: Int(track.streamIndex),
          language: track.language,
          title: track.title,
          codecName: track.codecName,
          isDefault: track.isDefault,
          isBitmap: track.isBitmap
        )
      } ?? []

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
      maxFrameAverageLightLevel: info.maxFrameAverageLightLevel > 0
        ? UInt(info.maxFrameAverageLightLevel) : nil,
      masteringDisplayMaxLuminance: info.masteringDisplayMaxLuminance > 0
        ? Float(info.masteringDisplayMaxLuminance) : nil,
      masteringDisplayMinLuminance: info.masteringDisplayMinLuminance > 0
        ? Float(info.masteringDisplayMinLuminance) : nil,
      audioCodecName: info.audioCodecName,
      audioSampleRate: info.audioSampleRate > 0 ? Int(info.audioSampleRate) : nil,
      audioChannels: info.audioChannels > 0 ? Int(info.audioChannels) : nil,
      audioTracks: audioTracks,
      subtitleTracks: subtitleTracks,
      sampleAspectRatioNum: Int(info.sampleAspectRatioNum),
      sampleAspectRatioDen: Int(info.sampleAspectRatioDen),
      decoderName: finalDecoderName,
      decoderDescription: finalDecoderDescription,
      didSynthesizeExtradata: demuxer.didSynthesizeExtradata
    )

    // Phase 4: Initialize ASS pipeline
    self.assPipeline = ASSSubtitlePipeline(videoInfo: self.videoInfo)

    // Pass extradata for the currently selected subtitle stream (if ASS header)
    let selectedSubtitleIndex = demuxer.selectedSubtitleStreamIndex()
    if selectedSubtitleIndex >= 0 {
      if let config = demuxer.getSubtitleDecoderConfig(forStream: Int32(selectedSubtitleIndex)) {
        self.assPipeline.configureHeaderIfNeeded(from: config)
      }
    }
  }

  deinit {
    close()
  }

  /// Closes the decoder safely, ensuring all pending operations complete
  public func close() {
    lock.lock()
    defer { lock.unlock() }

    guard !isClosed else { return }
    isClosed = true

    sampleBufferBuilder = nil

    // Close FFmpegDecoder
    decoder?.close()
    decoder = nil

    // Close FFmpegDemuxer
    demuxer?.close()
    demuxer = nil
  }

  // MARK: - I/O Cancellation

  public func requestDemuxAbort() async {
    await withCheckedContinuation { continuation in
      demuxQueue.async { [weak self] in
        self?.demuxer?.requestAbortIO()
        continuation.resume()
      }
    }
  }

  public func clearDemuxAbort() async {
    await withCheckedContinuation { continuation in
      demuxQueue.async { [weak self] in
        self?.demuxer?.clearAbortIO()
        continuation.resume()
      }
    }
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

        // Priority: Serve pending restoration packets first (from seek)
        self.lock.lock()
        // Check if we have pending packets
        if !self.pendingContextRestorationPackets.isEmpty {
          let packet = self.pendingContextRestorationPackets.removeFirst()
          self.lock.unlock()
          let data = self.convertPacket(packet)
          continuation.resume(returning: data)
          return
        }

        guard !self.isClosed, let demuxer = self.demuxer else {
          self.lock.unlock()
          continuation.resume(returning: nil)
          return
        }

        // Serve queued audio packets from seek operations first
        if let queuedAudioPacket = demuxer.popQueuedAudioPacket() {
          self.lock.unlock()
          let packet = self.convertPacket(queuedAudioPacket)
          continuation.resume(returning: packet)
          return
        }

        self.lock.unlock()

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
          // Use SampleBufferBuilder for passthrough if available
          if let builder = self.sampleBufferBuilder,
            self.hardwareDecodeMode == .passThrough
          {
            do {
              let sampleBuffer = try builder.createSampleBuffer(
                from: packet.data,
                pts: packet.pts,
                dts: packet.dts,
                duration: packet.duration,
                forPassthrough: true
              )

              let frame = VideoFrame(
                sampleBuffer: sampleBuffer,
                presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
                isHDR: self.videoInfo.isHDR,
                colorTransfer: Int(self.videoInfo.colorTransfer),
                doviProfile: self.videoInfo.isDolbyVision
                  ? Int(self.videoInfo.doviProfile ?? 0) : 0
              )
              results.append(.video(frame))
            } catch {
            }
          } else if let ffmpegFrames = decoder.decodeVideoPacket(withAllFrames: packet) {
            // Fallback to FFmpeg decode path
            for ffmpegFrame in ffmpegFrames {

              if let frame = self.makeVideoFrame(
                pixelBuffer: ffmpegFrame.pixelBuffer,
                presentationTime: ffmpegFrame.presentationTime,
                doviProfile: Int(ffmpegFrame.doviProfile)
              ) {
                results.append(.video(frame))
              }
            }
          }
        }
        // Handle audio packets - typically 1:1 packet-to-frame, but TrueHD can have multiple
        else if packet.isAudio {
          if let audioFrames = decoder.decodeAudioPacket(withAllFrames: packet) {
            for audioFrameObj in audioFrames {
              results.append(
                .audio(audioFrameObj.pcmBuffer, audioFrameObj.presentationTime))
            }
          }
        }
        // Handle subtitle packets
        else if packet.isSubtitle {
          if let decodedFrame = decoder.decodePacket(packet),
            let subtitleFrameObj = decodedFrame as? FFmpegSubtitleFrame
          {
            var subtitleContent: SubtitleContent = .text("")

            if let text = subtitleFrameObj.text {
              var cleanText = text
              if subtitleFrameObj.isASS {
                // Forward ASS event text to renderer (not the original packet data).
                let duration = subtitleFrameObj.endTime - subtitleFrameObj.startTime
                self.assPipeline.processASS(
                  text: text,
                  packetData: packet.data,
                  pts: subtitleFrameObj.startTime,
                  duration: duration
                )

                // For the UI, we still want to show something as fallback/debug.
                cleanText = self.cleanSubtitleText(text)
              }
              subtitleContent = .text(cleanText)
            } else if let bitmaps = subtitleFrameObj.bitmaps, !bitmaps.isEmpty {
              var swiftBitmaps: [SubtitleBitmap] = []
              for bitmapObj in bitmaps {
                let rect = CGRect(
                  x: bitmapObj.normalizedX,
                  y: bitmapObj.normalizedY,
                  width: bitmapObj.normalizedWidth,
                  height: bitmapObj.normalizedHeight
                )
                let swiftBitmap = SubtitleBitmap(
                  data: bitmapObj.data,
                  width: Int(bitmapObj.width),
                  height: Int(bitmapObj.height),
                  rect: rect
                )
                swiftBitmaps.append(swiftBitmap)
              }
              subtitleContent = .bitmaps(swiftBitmaps)
            }

            let frame = SubtitleFrame(
              content: subtitleContent,
              isASS: subtitleFrameObj.isASS,
              startTime: subtitleFrameObj.startTime,
              endTime: subtitleFrameObj.endTime
            )
            results.append(.subtitle(frame))
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

  /// Flush the audio decoder to signal end of stream
  /// Must be called before draining remaining frames
  public func flushAudioDecoder() async {
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

        decoder.flushAudioDecoder()
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

  /// Drain remaining buffered audio frames from the decoder after flush
  /// Returns nil when all frames have been drained
  public func drainAudioFrame() async -> (AVAudioPCMBuffer, Double)? {
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

        guard let audioFrameObj = decoder.drainAudioFrame() else {
          continuation.resume(returning: nil)
          return
        }

        continuation.resume(
          returning: (audioFrameObj.pcmBuffer, audioFrameObj.presentationTime)
        )
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

}
