//
//  MediaPlayer.swift
//  VidCore
//
//  High-level video player with playback orchestration
//
//  Decoupled Architecture:
//  - MediaPlayer (MainActor): Orchestrates high-level state, user input, and UI/Debug mirroring.
//

import Foundation
import Observation

/// High-level video player that orchestrates decoding, rendering, and audio playback.
///
/// `MediaPlayer` provides a complete playback solution by managing the demux/decode/display
/// pipeline, A/V synchronization, seeking, and state management.
///
/// ## Example
/// ```swift
/// let player = MediaPlayer()
/// try await player.load(url: videoURL)
/// player.play()
/// ```
@Observable
@MainActor
public class MediaPlayer {
    // MARK: - Public State

    /// Current playback state
    public internal(set) var state: PlaybackState = .idle

    /// Current playback time in seconds
    public internal(set) var currentTime: Double = 0

    /// Total duration in seconds
    public internal(set) var duration: Double = 0

    /// Video metadata (dimensions, frame rate, codec, etc.)
    public internal(set) var videoInfo: VideoInfo?

    /// Current frame for rendering (Mirrored from Display Loop for Debug/UI)
    /// Note: This is NOT the source of truth for the screen.
    public internal(set) var currentFrame: VideoFrame?

    /// Currently displayed subtitle
    public internal(set) var currentSubtitle: SubtitleFrame?

    /// Whether the video has an audio track
    public internal(set) var hasAudio: Bool = false

    /// Real-time debug statistics
    public internal(set) var debugStats = PlayerDebugStats()

    /// View size for subtitle rendering (updated by UI)
    public var viewSize: CGSize = .zero
    /// Display scale for subtitle rendering
    public var contentScale: CGFloat = 2.0

    // MARK: - Volume Control

    /// Playback volume (0.0 to 1.0)
    public var volume: Double = 1.0 {
        didSet {
            let clamped = max(0.0, min(volume, 1.0))
            if volume != clamped {
                volume = clamped
                return
            }
            Task { await worker.updateVolume(volume) }
        }
    }

    /// Playback rate (0.25 to 3.0 recommended)
    public var playbackRate: Double = 1.0 {
        didSet {
            let clamped = max(0.1, min(playbackRate, 32.0))
            if playbackRate != clamped {
                playbackRate = clamped
                return
            }
            if state == .playing {
                Task { await playbackClock.setRate(clamped) }
                audioOutput.setPlaybackState(isPlaying: true, rate: clamped)
            }
        }
    }

    private var preMuteVolume: Double = 1.0

    /// Whether audio is muted
    public var isMuted: Bool {
        get { volume == 0 }
        set {
            if newValue {
                preMuteVolume = volume > 0 ? volume : 1.0
                volume = 0
            } else {
                volume = preMuteVolume
            }
        }
    }

    /// Toggle mute state
    public func toggleMute() {
        isMuted.toggle()
    }

    // MARK: - Internal Components

    var audioOutput: AudioRendering
    var decoder: MediaDecoder?
    var packetQueue: PacketQueue
    var buffers: Buffers

    var playbackClock: PlaybackClock
    weak var renderer: VideoRendererTarget?

    // Debug/stat tracking
    var lastVideoPTS: Double = 0
    var lastStatsUpdateTime: TimeInterval = 0

    // Task management
    @ObservationIgnored
    lazy var worker = PlaybackWorker(
        decoder: nil,
        packetQueue: packetQueue,
        renderer: nil,
        audioOutput: audioOutput,
        delegate: self
    )
    var currentSeekTask: Task<Void, Never>?
    var isScrubbing: Bool = false
    var wasPlayingBeforeScrub: Bool = false
    @ObservationIgnored
    lazy var displayLink = DisplayLink { [weak self] in
        guard let self = self else { return }
        Task { @MainActor in
            await self.updateTimeFromClock()
        }
    }

    var subtitles: [SubtitleFrame] = []
    var lastSubtitleUpdateTime: Double = 0
    var lastScrubFrameTime: Double?
    var subtitleRenderTask: Task<Void, Never>?
    var pendingASSRenderTime: Double?
    var lastASSRenderTime: Double = 0
    var assAnimatingUntilTime: Double = 0

    /// Helper to track if we requested play but are waiting for first frame
    var pendingPlay: Bool = false

    // MARK: - Initialization

    /// Creates a new video player with deferred loading.
    ///
    /// Use this initializer when you need to configure the player before loading a URL,
    /// or when the URL is not yet available. Call `load(url:)` to load a video.
    ///
    /// - Parameter buffers: Buffer configuration preset. Defaults to `.auto` which detects
    ///   the decoder type at load time and uses appropriate sizes.
    public init(buffers: Buffers = .auto) {
        self.buffers = buffers

        // Create initial buffers with appropriate sizes
        let packetQueueSize = buffers.packetQueueSize
        self.packetQueue = PacketQueue(maxSize: packetQueueSize)

        let forceFallback = SystemAudioRenderer.isForceFallbackEnabled
        let audioRenderer = SystemAudioRenderer(
            enabled: SystemAudioRenderer.isSupportedInCurrentProcess && !forceFallback
        )
        if audioRenderer.isEnabled {
            self.audioOutput = audioRenderer
        } else {
            self.audioOutput = AudioEngineRenderer()
        }
        self.playbackClock = PlaybackClock(audioRenderer: audioRenderer.renderer)
    }

    /// Creates a new video player and immediately loads a video.
    ///
    /// This initializer is a convenience for the common case where you have a URL
    /// and want to start playback immediately. For `.auto` buffer configuration,
    /// hardware acceleration is detected immediately and appropriate buffer sizes
    /// are used.
    ///
    /// - Parameters:
    ///   - url: The URL of the video file to load
    ///   - buffers: Buffer configuration preset. Defaults to `.auto`.
    public convenience init(url: URL, buffers: Buffers = .auto) {
        // For auto mode with a URL, detect hardware immediately
        let effectiveBuffers: Buffers
        switch buffers {
        case .auto:
            let isHardware = MediaDecoder.willUseHardwareAcceleration(for: url)
            effectiveBuffers = isHardware ? .hardware : .software
        default:
            effectiveBuffers = buffers
        // Debug logging removed: noisy in Quick Look extensions.
        }

        // Debug logging removed: noisy in Quick Look extensions.
        self.init(buffers: effectiveBuffers)
    }

    // MARK: - Public API

    /// Sets the target renderer for video frames and applies the shared timebase.
    /// - Parameter target: The renderer target to use.
    public func setRenderer(_ target: VideoRendererTarget?) async {
        await MainActor.run {
            self.renderer = target
            self.configureRenderers(for: target)
        }
        await worker.updateRenderer(target)
    }

    /// Sets the source for display-synchronized updates (e.g., an `NSView` or `NSWindow`).
    ///
    /// This ensures that the progress bar, playback timing, and subtitles are updated exactly
    /// when the display refreshes. For multi-monitor setups, providing the rendering view
    /// as the source ensures synchronization with the specific display showing the video.
    ///
    /// - Parameter source: The `DisplayLinkSource` to use for timing updates.
    public func setDisplayLinkSource(_ source: DisplayLinkSource?) {
        displayLink.setSource(source)
    }

    @MainActor
    private func configureRenderers(for target: VideoRendererTarget?) {
        if let layerRenderer = target as? LayerRenderer {
            Task { await playbackClock.attachVideoRenderer(layerRenderer.displayLayer) }
        } else {
            Task { await playbackClock.attachVideoRenderer(nil) }
        }
    }

    /// Load a video file for playback.
    ///
    /// - Parameter url: The file URL of the video to load.
    /// - Throws: `MediaPlayerError` if the file cannot be loaded.
    public func load(url: URL) async throws {
        hasAudio = false
        state = .loading

        // Handle auto-detection for deferred loading - resize buffers if needed
        if case .auto = buffers {
            let isHardware = MediaDecoder.willUseHardwareAcceleration(for: url)
            let targetBuffer: Buffers = isHardware ? .hardware : .software

            // Check if we need to resize buffers
            let currentPacketSize = packetQueue.maxSize
            let targetPacketSize = targetBuffer.packetQueueSize

            if currentPacketSize != targetPacketSize {
                // Debug logging removed: noisy in Quick Look extensions.

                // Recreate buffers with correct sizes
                await packetQueue.reset()

                packetQueue = PacketQueue(maxSize: targetPacketSize)
                await worker.updatePacketQueue(packetQueue)
            }
        }

        do {
            // Check if we can use hardware acceleration (and thus pass-through)
            let supportsHardware = MediaDecoder.willUseHardwareAcceleration(for: url)
            // Use pass-through for hardware, standard decode otherwise
            let decodeMode: MediaDecoder.HardwareDecodeMode =
                supportsHardware ? .passThrough : .decode

            decoder = try MediaDecoder(url: url, hardwareDecodeMode: decodeMode)
            if let decoder = decoder {
                await worker.updateDecoder(decoder)
                await worker.updateRenderer(renderer)
                await worker.updateVolume(volume)

                duration = decoder.videoInfo.duration
                videoInfo = decoder.videoInfo
                hasAudio = !decoder.videoInfo.audioTracks.isEmpty
                updateDisplayLinkFrameRate(isAnimating: false, isASSActive: false)

                // Sync selected audio track with demuxer's default selection
                if hasAudio {
                    let selectedStreamIndex = await decoder.selectedAudioStreamIndex()
                    selectedAudioTrackIndex =
                        decoder.videoInfo.audioTracks.firstIndex {
                            $0.streamIndex == selectedStreamIndex
                        } ?? 0
                } else {
                    selectedAudioTrackIndex = -1
                }

                // Sync selected subtitle track
                if !decoder.videoInfo.subtitleTracks.isEmpty {
                    let selectedStreamIndex = await decoder.selectedSubtitleStreamIndex()
                    selectedSubtitleTrackIndex =
                        decoder.videoInfo.subtitleTracks.firstIndex {
                            $0.streamIndex == selectedStreamIndex
                        }
                        ?? -1
                } else {
                    selectedSubtitleTrackIndex = -1
                }

                await refreshDebugStats()

                // Only prime if we actually have video dimensions
                if decoder.videoInfo.width > 0 && decoder.videoInfo.height > 0 {
                    if let firstFrame = await worker.primeFirstVideoFrame() {
                        await renderFrame(firstFrame, flushRenderer: false)
                        await playbackClock.seek(to: firstFrame.presentationTime)
                    }
                } else {
                    // For audio-only, just seek the clock to 0
                    await playbackClock.seek(to: 0)
                }
            }
            state = .ready
        } catch {

            state = .error(.decoderInitFailed(error.localizedDescription))
            throw MediaPlayerError.decoderInitFailed(error.localizedDescription)
        }
    }

    /// Whether the player is currently playing.
    public var isPlaying: Bool {
        state == .playing
    }

    /// Start or resume playback.
    public func play() {
        guard state == .ready || state == .paused || state == .finished else { return }
        let clampedRate = max(0.1, min(playbackRate, 32.0))

        if state == .finished {
            // Debug logging removed: noisy in Quick Look extensions.
            Task {
                await seek(to: 0)
                await packetQueue.resume()
                state = .ready
                // Debug logging removed: noisy in Quick Look extensions.
                play()
            }
            return
        }

        if state == .paused {
            // Debug logging removed: noisy in Quick Look extensions.
            state = .playing
            Task { await playbackClock.play(rate: clampedRate) }
            audioOutput.setPlaybackState(isPlaying: true, rate: clampedRate)

            Task {
                await packetQueue.resume()
            }

            startTasks()
            startTimeUpdates()
            return
        }

        // Start playback (clock will start when first frame renders)
        pendingPlay = true
        state = .playing
        audioOutput.setPlaybackState(isPlaying: true, rate: clampedRate)

        startTasks()
        startTimeUpdates()
    }

    /// Pause playback.
    public func pause() {
        guard state == .playing else { return }

        pendingPlay = false
        state = .paused
        Task { await playbackClock.pause() }
        audioOutput.setPlaybackState(isPlaying: false, rate: playbackRate)

        Task {
            await packetQueue.suspend()
        }
        stopTimeUpdates()
    }

    /// Toggle between play and pause.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seek to a specific time.
    ///
    /// - Parameters:
    ///   - seconds: Target time in seconds.
    public func seek(to seconds: Double) async {
        await beginScrub()
        await scrub(to: seconds)
        await endScrub()
    }

    /// Close the player and release resources.
    public func close() async {
        currentSeekTask?.cancel()
        await decoder?.requestDemuxAbort()
        _ = await currentSeekTask?.result
        currentSeekTask = nil

        if isPlaying {
            pause()
        }

        await audioOutput.flush()

        await stopTasks()
        await playbackClock.pause()
        if let sbRenderer = renderer as? SampleBufferRenderer {
            sbRenderer.flush()
        }
        await audioOutput.flush()

        await packetQueue.reset()

        decoder?.close()
        decoder = nil
        await worker.updateDecoder(nil)

        currentFrame = nil
        currentSubtitle = nil
        subtitles.removeAll()
        hasAudio = false

        state = .idle
    }

    // MARK: - Internal Helpers

    func renderFrame(_ frame: VideoFrame, flushRenderer: Bool) async {
        if flushRenderer, let sbRenderer = renderer as? SampleBufferRenderer {
            sbRenderer.flush()
        }
        currentFrame = frame
        currentTime = frame.presentationTime
        updateSubtitles(for: frame.presentationTime)
        await renderer?.enqueue(frame)
        await refreshDebugStats(videoPTS: frame.presentationTime)
    }

    nonisolated func snapshotCurrentTime() async -> Double {
        await MainActor.run { self.currentTime }
    }

    nonisolated func snapshotDuration() async -> Double {
        await MainActor.run { self.duration }
    }

    // MARK: - Task Management

    func startTasks() {
        // Only start if not already running
        Task { await worker.start() }
    }

    func stopTasks() async {
        await worker.stop()

        stopTimeUpdates()
    }

    func startTimeUpdates() {
        displayLink.start()
    }

    func stopTimeUpdates() {
        displayLink.stop()
        subtitleRenderTask?.cancel()
        subtitleRenderTask = nil
        pendingASSRenderTime = nil
    }

    private func updateTimeFromClock() async {
        let clockTime = await playbackClock.getCurrentTime()
        var time = clockTime

        // Steer clock if audio renderer provides a more accurate PTS (e.g. AudioEngineRenderer fallback)
        if let audioPTS = await audioOutput.currentPlaybackPTS() {
            let drift = abs(audioPTS - clockTime)
            if drift > 0.020 {  // 20ms threshold
                await playbackClock.setTime(audioPTS)
                time = audioPTS
            }
        }

        self.currentTime = time
        self.updateSubtitles(for: time)
    }

    // MARK: - Cleanup

    /// Synchronously cancel all background tasks.
    public nonisolated func cancelAllTasks() {
        cancelLocalTasks()
        Task { @MainActor [weak self] in
            self?.currentSeekTask?.cancel()
        }
    }

    private nonisolated func cancelLocalTasks() {
        Task { @MainActor [weak self] in
            self?.stopTimeUpdates()
            await self?.worker.stop()
        }
    }

    /// Synchronous close for use from deinit or when async cannot be awaited.
    public nonisolated func closeSync() {
        cancelAllTasks()

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if isPlaying {
                    pause()
                }

                let audioOutput = self.audioOutput
                let playbackClock = self.playbackClock
                let renderer = self.renderer
                let decoder = self.decoder

                Task {
                    await decoder?.requestDemuxAbort()
                    await audioOutput.flush()
                }
                decoder?.close()
                self.decoder = nil
                Task { await worker.updateDecoder(nil) }
                currentFrame = nil

                Task { await playbackClock.pause() }
                if let sbRenderer = renderer as? SampleBufferRenderer {
                    sbRenderer.flush()
                }

                state = .idle

                let pq = packetQueue
                Task.detached(priority: .high) {
                    await pq.reset()
                }
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    if isPlaying {
                        pause()
                    }

                    let audioOutput = self.audioOutput
                    let playbackClock = self.playbackClock
                    let renderer = self.renderer
                    let decoder = self.decoder

                    Task {
                        await decoder?.requestDemuxAbort()
                        await audioOutput.flush()
                    }
                    decoder?.close()
                    self.decoder = nil
                    Task { await worker.updateDecoder(nil) }
                    currentFrame = nil

                    Task { await playbackClock.pause() }
                    if let sbRenderer = renderer as? SampleBufferRenderer {
                        sbRenderer.flush()
                    }

                    state = .idle

                    let pq = packetQueue
                    Task.detached(priority: .high) {
                        await pq.reset()
                    }
                }
            }
        }
    }

    // MARK: - Audio Track Selection

    /// Index of the currently selected audio track in the audioTracks array.
    /// -1 if no audio track is selected.
    public internal(set) var selectedAudioTrackIndex: Int = -1

    // MARK: - Subtitle Track Selection

    /// Index of the currently selected subtitle track.
    /// -1 if no subtitle track is selected (subtitles disabled).
    public internal(set) var selectedSubtitleTrackIndex: Int = -1

    nonisolated deinit {
        cancelLocalTasks()
    }
}
