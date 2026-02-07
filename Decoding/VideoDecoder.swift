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

// MARK: - SampleBufferBuilder Config Bridging

/// Convert FFmpegDemuxer's config dictionary to SampleBufferBuilderConfig.
private func createSampleBufferBuilder(from config: [String: Any]) throws -> SampleBufferBuilder {
  guard let codecNum = config["codec"] as? NSNumber,
    let width = config["width"] as? NSNumber,
    let height = config["height"] as? NSNumber,
    let extradata = config["extradata"] as? Data,
    let timeBaseNum = config["timeBaseNum"] as? NSNumber,
    let timeBaseDen = config["timeBaseDen"] as? NSNumber
  else {
    throw SampleBufferBuilderError.noExtradata
  }

  let codec: SampleBufferBuilderCodec = codecNum.intValue == 0 ? .hevc : .h264

  let sbConfig = SampleBufferBuilderConfig(
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

  return try SampleBufferBuilder(config: sbConfig)
}

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

  private var demuxer: FFmpegDemuxer?
  private var decoder: FFmpegDecoder?
  private var sampleBufferBuilder: SampleBufferBuilder?

  /// Renderer for ASS/SSA subtitles
  public let assRenderer: LibASSRenderer?

  private let url: URL

  /// Current hardware decode mode
  public let hardwareDecodeMode: HardwareDecodeMode

  // Separate queues for demuxing and decoding to enable parallelism
  private let demuxQueue = DispatchQueue(label: "com.vidpreview.demux", qos: .userInitiated)
  private let decodeQueue = DispatchQueue(
    label: "com.vidpreview.decode", qos: .userInitiated, attributes: .concurrent)

  private let lock = NSLock()
  private var isClosed = false

  // Queue for packets needed to restore decoder context after a seek (Keyframe...Target)
  // These are re-emitted via demuxNextPacket to ensure the renderer gets the full GOP
  private var pendingContextRestorationPackets: [FFmpegDemuxerPacket] = []

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
          print(
            "[VideoDecoder] Using SampleBufferBuilder (DoVi: \(builder.isDolbyVision), profile: \(builder.dolbyVisionProfile))"
          )
          if builder.isDolbyVision {
            finalDecoderName = "SampleBufferBuilder (DoVi P\(builder.dolbyVisionProfile))"
          } else {
            finalDecoderName = "SampleBufferBuilder (\(info.codecName))"
          }
          finalDecoderDescription = "Hardware Passthrough (SampleBufferBuilder)"
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

    // Phase 4: Initialize LibASSRenderer if needed
    // We always initialize it to be safe, but only use it if we have ASS tracks or if packets are ASS.
    // Also, we need to pass extradata if available.
    self.assRenderer = LibASSRenderer()

    // Pass extradata from demuxer (if any) to ASS renderer
    if let subs = demuxer.getSubtitleTracks() {
      for sub in subs {
        if sub.codecName == "ass" || sub.codecName == "ssa" {
          if let config = demuxer.getSubtitleDecoderConfig(forStream: Int32(sub.streamIndex)),
            let extradata = config["subtitleExtradata"] as? Data,
            let header = String(data: extradata, encoding: .utf8)
          {
            self.assRenderer?.configure(withHeader: header)
          }
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
    packet.isSubtitle = demuxerPacket.isSubtitle
    packet.flags = demuxerPacket.isKeyframe ? 1 : 0  // AV_PKT_FLAG_KEY = 1
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
                // Forward valid ASS packet to renderer
                // Use decoded timestamps (seconds) instead of raw packet PTS
                let duration = subtitleFrameObj.endTime - subtitleFrameObj.startTime
                self.assRenderer?.processPacket(
                  packet.data, pts: subtitleFrameObj.startTime, duration: duration)

                // For the UI, we still want to show something?
                // If we rely on LibASSRenderer, we might suppress the text content here
                // or keep it as backup/debug.
                // But VideoPlayer needs to know to render from assRenderer.
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

  // MARK: - Passthrough Context

  public func consumePendingPassthroughFrames() async -> [VideoFrame] {
    await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: [])
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed,
          self.hardwareDecodeMode == .passThrough,
          let builder = self.sampleBufferBuilder,
          !self.pendingContextRestorationPackets.isEmpty
        else {
          continuation.resume(returning: [])
          return
        }

        let packets = self.pendingContextRestorationPackets
        self.pendingContextRestorationPackets.removeAll()

        var frames: [VideoFrame] = []
        frames.reserveCapacity(packets.count)

        for packet in packets {
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
              doviProfile: self.videoInfo.isDolbyVision ? Int(self.videoInfo.doviProfile ?? 0) : 0
            )
            frames.append(frame)
          } catch {
          }
        }

        continuation.resume(returning: frames)
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

  // MARK: - Seeking

  public func seek(to seconds: Double) async throws -> VideoFrame? {
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

        // Dispatch based on available decoder
        if self.hardwareDecodeMode == .passThrough, self.sampleBufferBuilder != nil {
          do {
            let frame = try self.seekPassthrough(to: seconds)
            continuation.resume(returning: frame)
          } catch {
            continuation.resume(throwing: error)
          }
        } else if self.decoder != nil {
          do {
            let frame = try self.seekFFmpeg(to: seconds)
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

  // MARK: - Subtitle Rendering

  /// Whether the currently selected subtitle track is ASS/SSA.
  public var isCurrentSubtitleTrackASS: Bool {
    guard let demuxer = demuxer else { return false }
    let index = demuxer.selectedSubtitleStreamIndex()
    if index < 0 { return false }
    // Find track info
    if let tracks = demuxer.getSubtitleTracks(),
      let track = tracks.first(where: { $0.streamIndex == index })
    {
      return track.codecName == "ass" || track.codecName == "ssa"
    }
    return false
  }

  /// Render current subtitle image for the given time.
  public func getSubtitleImage(at time: Double, size: CGSize, scale: CGFloat = 2.0) -> CGImage? {
    // Only render if we have an active ASS renderer and the current track requires it.
    if isCurrentSubtitleTrackASS, let renderer = assRenderer {
      return renderer.render(atTimestamp: time, size: size, scale: scale)
    }
    return nil
  }

  // MARK: - Private Helpers

  /// Cleans ASS/SSA formatted subtitle text.
  private func cleanSubtitleText(_ text: String) -> String {
    var cleaned = text

    // 1. Remove ASS event prefix (comma-separated fields)
    // Heuristic: If we find 8 or more commas at the start, drop them.
    // Standard format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    // User reported 8 commas: 14,0,Default,,0,0,0,,Text
    // We'll look for the first 8 or 9 fields.
    // Pattern: at least 8 groups of "something," at the start.
    // Use simple comma counting to be robust.

    let parts = cleaned.split(separator: ",", maxSplits: 10, omittingEmptySubsequences: false)
    if parts.count >= 9 {  // 8 commas implies 9 parts
      // Check if the first few parts look like metadata (digits, known styles)
      // Or just blindly take the 9th part (index 8) onwards.
      // Given "14,0,Default,,0,0,0,,Text", the text is parts[8...] joined back.
      // Or simply find the 8th comma index.

      // Let's count commas to find the cut point.
      var commaCount = 0
      var cutIndex: String.Index?

      for (index, char) in cleaned.enumerated() {
        if char == "," {
          commaCount += 1
          if commaCount == 8 {
            // Found the 8th comma. The text likely starts after this.
            let nextIndex = cleaned.index(cleaned.startIndex, offsetBy: index + 1)
            if nextIndex < cleaned.endIndex {
              cutIndex = nextIndex
            }
            // Keep checking if 9th comma exists? (Standard is 9)
            // But user log shows 8 commas. The last field (Text) contains the content.
            // If we cut after 8th comma: "I will make it happen."
            // If we wait for 9th, we might cut into text if user source is non-standard.
            // A safe heuristic involves checking what these fields are, but stripped is better.
            // Let's settle on stripping first 8 fields (8 commas).
            // But wait, if text has commas, simple split won't work perfectly if we don't limit splits?
            break
          }
        }
      }

      if let cutIndex = cutIndex {
        cleaned = String(cleaned[cutIndex...])
      }
    }

    // 2. Replace \N with newline
    cleaned = cleaned.replacingOccurrences(of: "\\N", with: "\n")
    cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")

    return cleaned
  }

  private func makeVideoFrame(
    pixelBuffer: CVPixelBuffer,
    presentationTime: Double,
    doviProfile: Int
  ) -> VideoFrame? {
    return VideoFrame(
      pixelBuffer: pixelBuffer,
      presentationTime: presentationTime,
      isHDR: self.videoInfo.isHDR,
      colorTransfer: self.videoInfo.colorTransfer,
      doviProfile: doviProfile
    )
  }

  private func seekPassthrough(to seconds: Double) throws -> VideoFrame? {
    guard let demuxer = self.demuxer, let builder = self.sampleBufferBuilder else { return nil }

    // Clear pending packets
    self.pendingContextRestorationPackets.removeAll()

    // Passthrough path: use demuxer for seeking and getting packets
    // Flush decoder to reset internal state (critical for audio PTS monotonicity reset)
    self.decoder?.flushCodecBuffers()

    guard demuxer.seek(toKeyframe: seconds) else {
      throw NSError(
        domain: "VideoDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed - seek error"])
    }

    // Collect packets from demuxer
    // Always collect until target for accurate seek
    guard let packets = demuxer.collectPackets(until: seconds), !packets.isEmpty else {
      throw NSError(
        domain: "VideoDecoder", code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Seek failed - no packets"])
    }

    if self.hardwareDecodeMode == .passThrough {
      // Passthrough seek: return a compressed sample buffer without decompression.
      // We still queue the GOP for AVSampleBufferDisplayLayer to rebuild context.
      var targetPacket: FFmpegDemuxerPacket?
      var firstKeyframe: FFmpegDemuxerPacket?
      var firstAfterTarget: FFmpegDemuxerPacket?
      var lastPacket: FFmpegDemuxerPacket?

      for packet in packets {
        lastPacket = packet
        if packet.isKeyframe, firstKeyframe == nil {
          firstKeyframe = packet
        }
        if firstAfterTarget == nil, packet.pts != Int64.min {
          let packetSeconds =
            Double(packet.pts) * Double(builder.timeBaseNum) / Double(builder.timeBaseDen)
          if packetSeconds >= seconds - 0.01 {
            firstAfterTarget = packet
          }
        }
      }

      if let candidate = firstAfterTarget, candidate.isKeyframe {
        targetPacket = candidate
      } else if let keyframe = firstKeyframe {
        targetPacket = keyframe
      } else {
        targetPacket = firstAfterTarget ?? lastPacket
      }

      if let targetPacket, targetPacket.isKeyframe {
        self.pendingContextRestorationPackets = packets.filter { $0 !== targetPacket }
      } else {
        self.pendingContextRestorationPackets = packets
      }

      guard let packet = targetPacket else {
        throw NSError(
          domain: "VideoDecoder", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "Seek failed - no packet found"])
      }

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
        doviProfile: self.videoInfo.isDolbyVision ? Int(self.videoInfo.doviProfile ?? 0) : 0
      )
      return frame
    }

    throw NSError(
      domain: "VideoDecoder", code: -3,
      userInfo: [NSLocalizedDescriptionKey: "Seek failed - passthrough only path"])
  }

  private func seekFFmpeg(to seconds: Double) throws -> VideoFrame? {
    guard let demuxer = self.demuxer, let decoder = self.decoder else { return nil }

    // Non-passthrough path: use demuxer to seek, decoder to decode

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
    let maxPackets = 200  // Safety break

    while packetCount < maxPackets {
      let shouldStop = autoreleasepool { () -> Bool in
        // Read next packet directly
        guard let demuxerPacket = demuxer.demuxNextPacket() else {
          return true  // EOF
        }

        // Filter for video packets
        if demuxerPacket.isVideo {
          packetCount += 1
          let packet = self.convertPacket(demuxerPacket)

          if let ffmpegFrames = decoder.decodeVideoPacket(withAllFrames: packet) {
            for ffmpegFrame in ffmpegFrames {
              let framePTS = ffmpegFrame.presentationTime

              // Always wait for target (accurate seek)
              if framePTS >= seconds - 0.05 {
                if let frame = self.makeVideoFrame(
                  pixelBuffer: ffmpegFrame.pixelBuffer,
                  presentationTime: framePTS,
                  doviProfile: Int(ffmpegFrame.doviProfile)
                ) {
                  foundFrame = frame
                  return true
                }
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

  // MARK: - Audio Track Management

  /// Get all available audio tracks from the container.
  /// - Returns: Array of audio track info, empty if no audio tracks.
  public func getAudioTracks() -> [AudioTrackInfo] {
    lock.lock()
    defer { lock.unlock() }
    return videoInfo.audioTracks
  }

  /// Get the currently selected audio stream index.
  /// - Returns: Stream index, or -1 if no audio.
  public func selectedAudioStreamIndex() -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, let demuxer = self.demuxer else { return -1 }
    return Int(demuxer.selectedAudioStreamIndex())
  }

  /// Switch to a different audio track by its stream index.
  /// This reinitializes the audio decoder for the new codec format.
  /// - Parameter streamIndex: The stream index to switch to.
  /// - Returns: true if successful, false on error.
  public func switchAudioTrack(to streamIndex: Int) async -> Bool {
    await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: false)
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed, let demuxer = self.demuxer, let decoder = self.decoder else {
          continuation.resume(returning: false)
          return
        }

        // Update demuxer to use the new audio stream
        guard demuxer.selectAudioStream(Int32(streamIndex)) else {
          continuation.resume(returning: false)
          return
        }

        // Build decoder config for the new audio stream
        guard let newDecoderConfig = self.buildAudioDecoderConfig(streamIndex: streamIndex) else {
          continuation.resume(returning: false)
          return
        }

        // Switch audio stream in decoder (handles codec reinitialization)
        let success = decoder.switchAudioStream(newDecoderConfig)
        continuation.resume(returning: success)
      }
    }
  }

  /// Build decoder configuration for a specific audio stream.
  private func buildAudioDecoderConfig(streamIndex: Int) -> [String: Any]? {
    guard let demuxer = self.demuxer else { return nil }
    return demuxer.getAudioDecoderConfig(forStream: Int32(streamIndex))
  }

  // MARK: - Subtitle Track Management

  /// Get all available subtitle tracks from the container.
  public func getSubtitleTracks() -> [SubtitleTrackInfo] {
    lock.lock()
    defer { lock.unlock() }
    return videoInfo.subtitleTracks
  }

  /// Get the currently selected subtitle stream index.
  public func selectedSubtitleStreamIndex() -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, let demuxer = self.demuxer else { return -1 }
    return Int(demuxer.selectedSubtitleStreamIndex())
  }

  /// Switch to a different subtitle track by its stream index.
  public func switchSubtitleTrack(to streamIndex: Int) async -> Bool {
    await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: false)
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed, let demuxer = self.demuxer, let decoder = self.decoder else {
          continuation.resume(returning: false)
          return
        }

        if streamIndex == -1 {
          // Disable subtitles
          _ = demuxer.selectSubtitleStream(-1)
          continuation.resume(returning: true)
          return
        }

        guard demuxer.selectSubtitleStream(Int32(streamIndex)) else {
          continuation.resume(returning: false)
          return
        }

        guard let newConfig = self.buildSubtitleDecoderConfig(streamIndex: streamIndex) else {
          continuation.resume(returning: false)
          return
        }

        let success = decoder.switchSubtitleStream(newConfig)
        continuation.resume(returning: success)
      }
    }
  }

  private func buildSubtitleDecoderConfig(streamIndex: Int) -> [String: Any]? {
    guard let demuxer = self.demuxer else { return nil }
    return demuxer.getSubtitleDecoderConfig(forStream: Int32(streamIndex))
  }
}
