//
//  MediaDecoder.swift
//  VidCore
//
//  High-performance video decoder orchestrating FFmpeg and hardware passthrough
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

extension FFmpegDemuxerPacket: @unchecked Sendable {}

/// High-performance video decoder using FFmpeg with passthrough hardware rendering when available.
public final class MediaDecoder: @unchecked Sendable {

    /// Modes for hardware acceleration
    public enum HardwareDecodeMode {
        case decode
        case passThrough
    }

    // Internal actors for thread safety
    let demuxerActor: DemuxerActor
    var decoderActor: DecoderActor?  // Optional because it might not be needed for passthrough

    var sampleBufferBuilder: SampleBufferBuilder?

    let assPipeline: ASSSubtitlePipeline

    public var assRenderer: LibASSRenderer? {
        assPipeline.renderer
    }

    private let url: URL
    public let hardwareDecodeMode: HardwareDecodeMode

    var isClosed = false

    // MARK: - Synchronization Helpers

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    func performUnderLock(_ body: () -> Void) {
        stateLock.lock()
        body()
        stateLock.unlock()
    }

    func checkIsClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isClosed
    }

    func getAndRemoveFirstPendingContextRestorationPacket() -> FFmpegDemuxerPacket? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if pendingContextRestorationIndex < pendingContextRestorationPackets.count {
            let packet = pendingContextRestorationPackets[pendingContextRestorationIndex]
            pendingContextRestorationIndex += 1
            if pendingContextRestorationIndex >= pendingContextRestorationPackets.count {
                pendingContextRestorationPackets.removeAll()
                pendingContextRestorationIndex = 0
            }
            return packet
        }
        pendingContextRestorationPackets.removeAll()
        pendingContextRestorationIndex = 0
        return nil
    }

    func getAndRemoveFirstPendingCarryoverPacket() -> FFmpegDemuxerPacket? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard pendingPassthroughCarryoverIndex < pendingPassthroughCarryoverPackets.count else {
            pendingPassthroughCarryoverPackets.removeAll()
            pendingPassthroughCarryoverIndex = 0
            return nil
        }
        let packet = pendingPassthroughCarryoverPackets[pendingPassthroughCarryoverIndex]
        pendingPassthroughCarryoverIndex += 1
        if pendingPassthroughCarryoverIndex >= pendingPassthroughCarryoverPackets.count {
            pendingPassthroughCarryoverPackets.removeAll()
            pendingPassthroughCarryoverIndex = 0
        }
        return packet
    }

    func setClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return false }
        isClosed = true
        return true
    }

    // MARK: - State Accessors

    // Public accessor for subtitle renderer (thread-safe)
    public var isASSActive: Bool {
        checkIsASSActive()
    }

    func checkIsASSActive() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isASSActive
    }

    // Cache for synchronous ASS check
    var _isASSActive: Bool = false

    // Pending restoration packets are kept here to be managed under lock
    // as they are part of the MediaDecoder seeking state machine.
    let stateLock = NSLock()
    var pendingContextRestorationPackets: [FFmpegDemuxerPacket] = []
    var pendingContextRestorationIndex: Int = 0
    var pendingPassthroughCarryoverPackets: [FFmpegDemuxerPacket] = []
    var pendingPassthroughCarryoverIndex: Int = 0
    var isSeeking = false

    /// Metadata about the video stream.
    public let videoInfo: VideoInfo

    // MARK: - Static Helpers

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

    public init(url: URL, hardwareDecodeMode: HardwareDecodeMode = .decode) throws {
        self.url = url
        self.hardwareDecodeMode = hardwareDecodeMode

        // Create FFmpegDemuxer
        let demuxer = try FFmpegDemuxer(url: url)
        // Read info synchronously during init
        guard let info = demuxer.getVideoInfo() else {
            throw NSError(
                domain: "MediaDecoder", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get media info"])
        }

        // Create the DemuxerActor with the created demuxer
        self.demuxerActor = DemuxerActor(demuxer: demuxer)

        // Configure SampleBufferBuilder for passthrough or internal decoding
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

        // Initialize FFmpegDecoder if needed
        var createdDecoder: FFmpegDecoder?
        if let decoderConfig = demuxer.getDecoderConfig() {
            do {
                createdDecoder = try FFmpegDecoder(demuxerConfig: decoderConfig)
                if self.sampleBufferBuilder == nil, let decoder = createdDecoder,
                    let decoderInfo = decoder.getVideoInfo()
                {
                    finalDecoderName = decoderInfo.decoderName
                    finalDecoderDescription = decoderInfo.decoderDescription
                    finalIsHardwareAccelerated = decoderInfo.isHardwareAccelerated
                }
            } catch {
                if self.sampleBufferBuilder == nil {
                    throw error
                }
            }
        }

        if let dec = createdDecoder {
            self.decoderActor = DecoderActor(decoder: dec)
        } else {
            self.decoderActor = nil
        }

        // Convert audio tracks
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

        // Convert subtitle tracks
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
            maxContentLightLevel: info.maxContentLightLevel > 0
                ? UInt(info.maxContentLightLevel) : nil,
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

        // Initialize ASS pipeline
        self.assPipeline = ASSSubtitlePipeline(videoInfo: self.videoInfo)

        let selectedSubtitleIndex = demuxer.selectedSubtitleStreamIndex()
        if selectedSubtitleIndex >= 0 {
            if let config = demuxer.getSubtitleDecoderConfig(
                forStream: Int32(selectedSubtitleIndex))
            {
                self.assPipeline.configureHeaderIfNeeded(from: config)
                self._isASSActive = self.assPipeline.isASSActive(for: demuxer)
            }
        }
    }

    deinit {
    }

    public func close() {
        guard setClosed() else { return }

        sampleBufferBuilder = nil
        performUnderLock {
            self.isSeeking = false
            self.pendingContextRestorationPackets.removeAll()
            self.pendingContextRestorationIndex = 0
            self.pendingPassthroughCarryoverPackets.removeAll()
            self.pendingPassthroughCarryoverIndex = 0
        }

        // Trigger async close on actors
        Task {
            await demuxerActor.requestAbortIO()
            await decoderActor?.close()
            await demuxerActor.close()
        }
    }

    // MARK: - I/O Cancellation

    public func requestDemuxAbort() async {
        await demuxerActor.requestAbortIO()
    }

    public func clearDemuxAbort() async {
        await demuxerActor.clearAbortIO()
    }

    // MARK: - Parallel Demux/Decode API

    /// Asynchronously demuxes the next packet from the container.
    ///
    /// This method prioritizes packets in the following order:
    /// 1. Pending packets from a seek operation (context restoration).
    /// 2. Audio packets queued during a seek (maintained by `DemuxerActor`).
    /// 3. Passthrough post-seek carryover packets.
    /// 4. New packets read directly from the demuxer.
    ///
    /// - Returns: The next `FFmpegDemuxerPacket`, or `nil` if end-of-file is reached or an error occurs.
    public func demuxNextPacket() async -> FFmpegDemuxerPacket? {
        // Priority 1: Pending restoration packets (from seek)
        if let packet = getAndRemoveFirstPendingContextRestorationPacket() {
            return packet
        }

        // Check seek/closed state under lock
        var shouldStop = false
        performUnderLock {
            if self.isClosed || self.isSeeking {
                shouldStop = true
            }
        }
        if shouldStop { return nil }

        // Priority 2: Queued audio packets (from seek)
        if let queuedAudioPacket = await demuxerActor.popQueuedAudioPacket() {
            return queuedAudioPacket
        }

        // Priority 3: Post-seek carryover packets
        if let carryoverPacket = getAndRemoveFirstPendingCarryoverPacket() {
            return carryoverPacket
        }

        // Priority 4: Fresh packet
        if let demuxerPacket = await demuxerActor.demuxNextPacket() {
            return demuxerPacket
        } else {
            return nil
        }
    }

    /// Asynchronously decodes a demuxed packet.
    ///
    /// - Parameter packet: The `FFmpegDemuxerPacket` to decode.
    /// - Returns: An array of `DecodedFrame` objects (video, audio, or subtitle). Returns an empty array if decoding produces no frames or if the decoder is closed.
    public func decodePacket(_ packet: FFmpegDemuxerPacket) async -> [DecodedFrame] {
        if checkIsClosed() {
            return []
        }

        var results: [DecodedFrame] = []

        if packet.isVideo {
            if let builder = self.sampleBufferBuilder, self.hardwareDecodeMode == .passThrough {
                do {
                    let sampleBuffer = try builder.createSampleBuffer(
                        from: packet,
                        pts: packet.pts,
                        dts: packet.dts,
                        duration: packet.duration,
                        forPassthrough: true,
                        ambientLightMetadata: packet.ambientLightMetadata,
                        isKeyframe: packet.isKeyframe
                    )
                    // ... creation logic ...
                    let frame = VideoFrame(
                        sampleBuffer: sampleBuffer,
                        presentationTime: CMTimeGetSeconds(sampleBuffer.presentationTimeStamp),
                        isHDR: self.videoInfo.isHDR,
                        colorTransfer: Int(self.videoInfo.colorTransfer),
                        doviProfile: self.videoInfo.isDolbyVision
                            ? Int(self.videoInfo.doviProfile ?? 0) : 0,
                        ambientLightMetadata: packet.ambientLightMetadata
                    )
                    results.append(.video(frame))
                } catch {}
            } else if let decoderActor = self.decoderActor,
                let ffmpegFrames = await decoderActor.decodeVideoPacket(withAllFrames: packet)
            {
                for ffmpegFrame in ffmpegFrames {
                    if let frame = self.makeVideoFrame(
                        pixelBuffer: ffmpegFrame.pixelBuffer,
                        presentationTime: ffmpegFrame.presentationTime,
                        doviProfile: Int(ffmpegFrame.doviProfile),
                        ambientLightMetadata: ffmpegFrame.ambientLightMetadata
                    ) {
                        results.append(.video(frame))
                    }
                }
            }
        } else if packet.isAudio {
            if let decoderActor = self.decoderActor,
                let audioFrames = await decoderActor.decodeAudioPacket(withAllFrames: packet)
            {
                for audioFrameObj in audioFrames {
                    results.append(
                        .audio(audioFrameObj.pcmBuffer, audioFrameObj.presentationTime))
                }
            }
        } else if packet.isSubtitle {
            if let decoderActor = self.decoderActor,
                let subtitleFrameObj = await decoderActor.decodeSubtitlePacket(packet)
            {
                // ... subtitle logic ...
                var subtitleContent: SubtitleContent = .text("")

                if let text = subtitleFrameObj.text {
                    var cleanText = text
                    if subtitleFrameObj.isASS {
                        let duration = subtitleFrameObj.endTime - subtitleFrameObj.startTime
                        self.assPipeline.processASS(
                            text: text,
                            packetData: packet.data,
                            pts: subtitleFrameObj.startTime,
                            duration: duration
                        )
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

        return results
    }

    // MARK: - Decoder Flush/Drain

    /// Asynchronously flushes the video decoder, clearing internal buffers.
    ///
    /// This must be called before seeking or when the stream continuity is broken to avoid decoding artifacts.
    public func flushMediaDecoder() async {
        await decoderActor?.flushMediaDecoder()
    }

    /// Asynchronously flushes the audio decoder, clearing internal buffers.
    public func flushAudioDecoder() async {
        await decoderActor?.flushAudioDecoder()
    }

    /// Asynchronously drains a pending video frame from the decoder.
    ///
    /// - Returns: A `VideoFrame` if available, or `nil` if the decoder is empty.
    public func drainVideoFrame() async -> VideoFrame? {
        guard let videoFrameObj = await decoderActor?.drainVideoFrame() else { return nil }

        return self.makeVideoFrame(
            pixelBuffer: videoFrameObj.pixelBuffer,
            presentationTime: videoFrameObj.presentationTime,
            doviProfile: Int(videoFrameObj.doviProfile),
            ambientLightMetadata: videoFrameObj.ambientLightMetadata
        )
    }

    /// Asynchronously drains a pending audio frame from the decoder.
    ///
    /// - Returns: A tuple containing the audio buffer and its presentation timestamp, or `nil`.
    public func drainAudioFrame() async -> (AVAudioPCMBuffer, Double)? {
        guard let audioFrameObj = await decoderActor?.drainAudioFrame() else { return nil }
        return (audioFrameObj.pcmBuffer, audioFrameObj.presentationTime)
    }

    // MARK: - Cover Image Extraction

    /// Asynchronously extracts the attached cover image (album art) from the file, if present.
    ///
    /// - Returns: The image data (e.g., JPEG/PNG), or `nil` if not found.
    public func extractCoverImage() async -> Data? {
        return await demuxerActor.extractCoverImage()
    }
}
