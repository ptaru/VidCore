//
//  VideoPlayer.swift
//  VidCore
//
//  High-level video player with playback orchestration
//
//  Decoupled Architecture:
//  - VideoPlayer (MainActor): Orchestrates high-level state, user input, and UI/Debug mirroring.
//

import Foundation
import Observation

/// High-level video player that orchestrates decoding, rendering, and audio playback.
///
/// `VideoPlayer` provides a complete playback solution by managing the demux/decode/display
/// pipeline, A/V synchronization, seeking, and state management.
///
/// ## Example
/// ```swift
/// let player = VideoPlayer()
/// try await player.load(url: videoURL)
/// player.play()
/// ```
@Observable
@MainActor
public class VideoPlayer {
  // MARK: - Public State

  /// Current playback state
  public private(set) var state: PlaybackState = .idle

  /// Current playback time in seconds
  public private(set) var currentTime: Double = 0

  /// Total duration in seconds
  public private(set) var duration: Double = 0

  /// Video metadata (dimensions, frame rate, codec, etc.)
  public private(set) var videoInfo: VideoInfo?

  /// Current frame for rendering (Mirrored from Display Loop for Debug/UI)
  /// Note: This is NOT the source of truth for the screen.
  public private(set) var currentFrame: VideoFrame?

  /// Currently displayed subtitle
  public private(set) var currentSubtitle: SubtitleFrame?

  /// Whether the video has an audio track
  public private(set) var hasAudio: Bool = false

  /// Real-time debug statistics
  public private(set) var debugStats = PlayerDebugStats()

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

  private var audioOutput: AudioRendering
  private var decoder: VideoDecoder?
  private var packetQueue: PacketQueue
  private var buffers: Buffers

  private var playbackClock: PlaybackClock
  private weak var renderer: VideoRendererTarget?

  // Debug/stat tracking
  private var lastVideoPTS: Double = 0
  private var lastStatsUpdateTime: TimeInterval = 0

  // Task management
  @ObservationIgnored
  private lazy var worker = PlaybackWorker(
    decoder: nil,
    packetQueue: packetQueue,
    renderer: nil,
    audioOutput: audioOutput,
    delegate: self
  )
  @ObservationIgnored
  private lazy var seekCoordinator = SeekCoordinator(player: self)
  @ObservationIgnored
  private lazy var displayLink = DisplayLink { [weak self] in
    guard let self = self else { return }
    Task { @MainActor in
      await self.updateTimeFromClock()
    }
  }

  private var subtitles: [SubtitleFrame] = []
  private var lastSubtitleUpdateTime: Double = 0
  private var lastScrubFrameTime: Double?

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
      print("[VideoPlayer] Using SystemAudioRenderer")
      self.audioOutput = audioRenderer
    } else {
      print("[VideoPlayer] Using AudioEngineRenderer (Fallback)")
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
      let isHardware = VideoDecoder.willUseHardwareAcceleration(for: url)
      effectiveBuffers = isHardware ? .hardware : .software
      print(
        "[VideoPlayer] Auto-detected \(isHardware ? "hardware" : "software") decoding for \(url.lastPathComponent)"
      )
    default:
      effectiveBuffers = buffers
    // Debug logging removed: noisy in Quick Look extensions.
    }

    // Debug logging removed: noisy in Quick Look extensions.
    self.init(buffers: effectiveBuffers)
  }

  // MARK: - Public API

  /// Sets the target renderer for video frames and applies the shared timebase.
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
  /// - Throws: `VideoPlayerError` if the file cannot be loaded.
  public func load(url: URL) async throws {
    hasAudio = false
    state = .loading

    // Handle auto-detection for deferred loading - resize buffers if needed
    if case .auto = buffers {
      let isHardware = VideoDecoder.willUseHardwareAcceleration(for: url)
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
      let supportsHardware = VideoDecoder.willUseHardwareAcceleration(for: url)
      // Use pass-through for hardware, standard decode otherwise
      let decodeMode: VideoDecoder.HardwareDecodeMode = supportsHardware ? .passThrough : .decode

      decoder = try VideoDecoder(url: url, hardwareDecodeMode: decodeMode)
      if let decoder = decoder {
        await worker.updateDecoder(decoder)
        await worker.updateRenderer(renderer)
        await worker.updateVolume(volume)

        duration = decoder.videoInfo.duration
        videoInfo = decoder.videoInfo

        // Sync selected audio track with demuxer's default selection
        if !decoder.videoInfo.audioTracks.isEmpty {
          let selectedStreamIndex = decoder.selectedAudioStreamIndex()
          selectedAudioTrackIndex =
            decoder.videoInfo.audioTracks.firstIndex { $0.streamIndex == selectedStreamIndex } ?? 0
        } else {
          selectedAudioTrackIndex = -1
        }

        // Sync selected subtitle track
        if !decoder.videoInfo.subtitleTracks.isEmpty {
          let selectedStreamIndex = decoder.selectedSubtitleStreamIndex()
          selectedSubtitleTrackIndex =
            decoder.videoInfo.subtitleTracks.firstIndex { $0.streamIndex == selectedStreamIndex }
            ?? -1
        } else {
          selectedSubtitleTrackIndex = -1
        }

        await refreshDebugStats()

        if let firstFrame = await worker.primeFirstVideoFrame() {
          await renderFrame(firstFrame, flushRenderer: false)
          await playbackClock.seek(to: firstFrame.presentationTime)
        }
      }
      state = .ready
    } catch {

      state = .error(.decoderInitFailed(error.localizedDescription))
      throw VideoPlayerError.decoderInitFailed(error.localizedDescription)
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

    // Debug logging removed: noisy in Quick Look extensions.
    state = .playing
    Task { await playbackClock.play(rate: clampedRate) }
    audioOutput.setPlaybackState(isPlaying: true, rate: clampedRate)

    startTasks()
    startTimeUpdates()
  }

  /// Pause playback.
  public func pause() {
    guard state == .playing else { return }

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
    await seekCoordinator.seek(to: seconds)
  }

  /// Close the player and release resources.
  public func close() async {
    await seekCoordinator.cancelAll()

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

  // MARK: - Scrubbing

  /// Begin a scrubbing session.
  ///
  /// This pauses playback, stops the decode loop, and prepares the player for rapid
  /// coalesced seeking. Use `scrub(to:)` to update the position.
  public func beginScrub() async {
    await seekCoordinator.beginScrub()
  }

  /// Update the scrub position.
  ///
  /// This method is lightweight and designed to be called frequently (e.g., from a slider drag).
  /// Updates are coalesced so that the decoder only processes the latest request.
  ///
  /// - Parameter time: The target time to scrub to.
  public func scrub(to time: Double) async {
    await seekCoordinator.scrub(to: time)
  }

  /// End the scrubbing session.
  ///
  /// - Parameter resumePlayback: Whether to resume playback after scrubbing ends.
  public func endScrub(resumePlayback: Bool) async {
    await seekCoordinator.endScrub(resumePlayback: resumePlayback)
  }

  // MARK: - Seek/Scrub Internals

  fileprivate func prepareForScrub() async -> PlaybackState {
    let previousState = state
    state = .scrubbing
    lastScrubFrameTime = nil

    await stopTasks()
    await playbackClock.pause()
    audioOutput.setPlaybackState(isPlaying: false, rate: playbackRate)
    await packetQueue.suspend()

    return previousState
  }

  fileprivate func performScrubSeek(to seconds: Double) async {
    guard let decoder = decoder else { return }
    let clampedSeconds = max(0, min(seconds, duration))

    do {
      if let frame = try await decoder.seek(to: clampedSeconds) {
        lastScrubFrameTime = frame.presentationTime
        await renderFrame(frame, flushRenderer: true)
      } else {
        currentTime = clampedSeconds
        updateSubtitles(for: clampedSeconds)
      }
    } catch {
      print("[VideoPlayer] Scrub seek failed: \(error)")
    }
  }

  fileprivate func performSeek(to seconds: Double, resumePlayback: Bool?) async {
    guard let decoder = decoder else { return }
    if Task.isCancelled { return }

    let clampedSeconds = max(0, min(seconds, duration))
    let wasPlaying = state == .playing
    let shouldResume = resumePlayback ?? wasPlaying

    state = .seeking
    await stopTasks()
    if Task.isCancelled { return }
    await playbackClock.pause()
    if Task.isCancelled { return }
    audioOutput.setPlaybackState(isPlaying: false, rate: playbackRate)
    await packetQueue.suspend()
    if Task.isCancelled { return }

    await resetPlaybackStateForSeek()
    if Task.isCancelled { return }

    do {
      if let seekFrame = try await decoder.seek(to: clampedSeconds) {
        if Task.isCancelled { return }
        await renderFrame(seekFrame, flushRenderer: true)
        if Task.isCancelled { return }
        await playbackClock.seek(to: seekFrame.presentationTime)
      } else {
        currentTime = clampedSeconds
        await playbackClock.seek(to: clampedSeconds)
      }

      await audioOutput.flush()
      if Task.isCancelled { return }

      startTasks()
      if Task.isCancelled { return }

      if shouldResume {
        let clampedRate = max(0.1, min(playbackRate, 32.0))
        state = .playing
        await playbackClock.play(rate: clampedRate)
        audioOutput.setPlaybackState(isPlaying: true, rate: clampedRate)
        await packetQueue.resume()
        startTimeUpdates()
      } else {
        state = .paused
        await packetQueue.suspend()
      }
    } catch {
      state = .paused
    }
  }

  fileprivate func finishScrub(at targetTime: Double, resumePlayback: Bool) async {
    state = .seeking
    let resumeTime = lastScrubFrameTime ?? targetTime
    await playbackClock.seek(to: resumeTime)
    await audioOutput.flush()

    await packetQueue.reset()
    subtitles.removeAll()
    currentSubtitle = nil
    lastSubtitleUpdateTime = 0

    if lastScrubFrameTime == nil, let decoder {
      do {
        if let frame = try await decoder.seek(to: targetTime) {
          await renderFrame(frame, flushRenderer: true)
          await playbackClock.seek(to: frame.presentationTime)
        }
      } catch {
        print("[VideoPlayer] final seek failed: \(error.localizedDescription)")
      }
    }

    if let decoder, decoder.hardwareDecodeMode == .passThrough {
      let contextFrames = await decoder.consumePendingPassthroughFrames()
      if let r = renderer {
        if let sbRenderer = r as? SampleBufferRenderer {
          sbRenderer.flush()
        }
        for contextFrame in contextFrames {
          await r.enqueue(contextFrame)
        }
        if let lastFrame = contextFrames.last {
          currentFrame = lastFrame
          currentTime = lastFrame.presentationTime
          updateSubtitles(for: lastFrame.presentationTime)
        }
      }
    }

    startTasks()

    if resumePlayback {
      let clampedRate = max(0.1, min(playbackRate, 32.0))
      state = .playing
      await playbackClock.play(rate: clampedRate)
      audioOutput.setPlaybackState(isPlaying: true, rate: clampedRate)
      await packetQueue.resume()
      startTimeUpdates()
    } else {
      state = .paused
      await packetQueue.suspend()
    }
    lastScrubFrameTime = nil

  }

  fileprivate func resetPlaybackStateForSeek() async {
    await packetQueue.reset()
    subtitles.removeAll()
    currentSubtitle = nil
    lastSubtitleUpdateTime = 0

    if let sbRenderer = renderer as? SampleBufferRenderer {
      sbRenderer.flush()
    }
  }

  fileprivate func renderFrame(_ frame: VideoFrame, flushRenderer: Bool) async {
    if flushRenderer, let sbRenderer = renderer as? SampleBufferRenderer {
      sbRenderer.flush()
    }
    currentFrame = frame
    currentTime = frame.presentationTime
    updateSubtitles(for: frame.presentationTime)
    await renderer?.enqueue(frame)
    await refreshDebugStats(videoPTS: frame.presentationTime)
  }

  fileprivate nonisolated func snapshotCurrentTime() async -> Double {
    await MainActor.run { self.currentTime }
  }

  fileprivate nonisolated func snapshotDuration() async -> Double {
    await MainActor.run { self.duration }
  }

  private func updateSubtitles(for time: Double) {
    // Ignore out-of-order frames to prevent flickering at subtitle boundaries
    // Only allow backwards jumps if they're significant (>1s, indicating a real seek)
    if time < lastSubtitleUpdateTime && (lastSubtitleUpdateTime - time) < 1.0 {
      return
    }
    lastSubtitleUpdateTime = time

    // Find the subtitle that matches current time
    // Use last (most recent) to ensure newer subtitles replace older overlapping ones
    var newSubtitle = subtitles.last { sub in
      time >= sub.startTime && (sub.endTime == nil || time <= sub.endTime!)
    }

    // Check for ASS rendering override
    if let decoder = decoder, decoder.isCurrentSubtitleTrackASS {
      // Only render if we have a valid size
      if viewSize.width > 0 && viewSize.height > 0 {
        let size = viewSize
        let scale = contentScale

        // Configure aspect ratio before rendering if needed
        if let info = videoInfo {
          let storageSize = CGSize(width: Double(info.width), height: Double(info.height))
          decoder.assRenderer?.setStorageSize(storageSize, aspect: info.displayAspectRatio)
        }

        // Offload rendering to background to avoid main thread hitches
        Task.detached(priority: .userInitiated) { [weak self, decoder] in
          if let image = decoder.getSubtitleImage(at: time, size: size, scale: scale) {
            await MainActor.run {
              guard let self = self else { return }

              // Ensure this update is still relevant (e.g. didn't seek away)
              // A simple check is if we're still playing or paused near this time.
              // For now, update regardless to ensure we don't miss frames.
              // The main actor serialization handles race on `currentSubtitle`.

              let newSubtitle = SubtitleFrame(
                content: .image(ImageBox(image)),
                isASS: true,
                startTime: time,
                endTime: nil  // ASS manages its own duration via the renderer
              )

              // Only update if changed
              if self.currentSubtitle != newSubtitle {
                self.currentSubtitle = newSubtitle
              }
            }
          } else {
            await MainActor.run {
              guard let self = self else { return }
              // Clear subtitle if no image returned (gap)
              // Only clear if the current subtitle IS an ASS subtitle (don't clear text subs here)
              // Actually, if we are in ASS mode, we should control the subtitle.
              if self.currentSubtitle?.isASS == true {
                self.currentSubtitle = nil
              }
            }
          }
        }
        return  // Early exit, async update will handle it
      }
    }

    // Only update if changed to avoid excessive SwiftUI view updates and flickering
    if newSubtitle != currentSubtitle {
      currentSubtitle = newSubtitle
    }
  }

  // MARK: - Task Management

  private func startTasks() {
    // Only start if not already running
    Task { await worker.start() }
  }

  private func stopTasks() async {
    await worker.stop()

    stopTimeUpdates()
  }

  private func startTimeUpdates() {
    displayLink.start()
  }

  private func stopTimeUpdates() {
    displayLink.stop()
  }

  private func updateTimeFromClock() async {
    let time = await playbackClock.getCurrentTime()
    self.currentTime = time
    self.updateSubtitles(for: time)
  }

  // MARK: - Cleanup

  /// Synchronously cancel all background tasks.
  public nonisolated func cancelAllTasks() {
    cancelLocalTasks()
    Task { @MainActor [weak self] in
      await self?.seekCoordinator.cancelAll()
    }
  }

  private nonisolated func cancelLocalTasks() {
    Task { @MainActor [weak self] in
      self?.displayLink.stop()
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

        Task { await audioOutput.flush() }
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

          Task { await audioOutput.flush() }
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

  /// All available audio tracks in the current video.
  public var audioTracks: [AudioTrackInfo] {
    videoInfo?.audioTracks ?? []
  }

  /// Index of the currently selected audio track in the audioTracks array.
  /// -1 if no audio track is selected.
  public private(set) var selectedAudioTrackIndex: Int = -1

  /// Select an audio track by its index in the audioTracks array.
  /// Flow: pause -> switch -> accurate seek -> resume
  /// - Parameter index: Index of the audio track to select.
  public func selectAudioTrack(at index: Int) async {
    guard let decoder = decoder else { return }
    guard index >= 0 && index < audioTracks.count else { return }
    guard index != selectedAudioTrackIndex else { return }

    let track = audioTracks[index]
    let currentPosition = currentTime
    let wasPlaying = state == .playing

    // 1. Pause playback
    if wasPlaying {
      pause()
    }

    // 2. Switch demuxer and decoder to the new audio stream
    let success = await decoder.switchAudioTrack(to: track.streamIndex)
    guard success else {
      if wasPlaying {
        play()
      }
      return
    }

    // Update state
    selectedAudioTrackIndex = index
    videoInfo = decoder.videoInfo

    // 3. Accurate seek to reset state and maintain position
    await seek(to: currentPosition)

    // 4. Resume playback if we were playing
    if wasPlaying {
      play()
    }
  }

  // MARK: - Subtitle Track Selection

  /// All available subtitle tracks in the current video.
  public var subtitleTracks: [SubtitleTrackInfo] {
    videoInfo?.subtitleTracks ?? []
  }

  /// Index of the currently selected subtitle track.
  /// -1 if no subtitle track is selected (subtitles disabled).
  public private(set) var selectedSubtitleTrackIndex: Int = -1

  /// Select a subtitle track.
  /// - Parameter index: Index of the track in `subtitleTracks`. Use -1 to disable subtitles.
  public func selectSubtitleTrack(at index: Int) async {
    guard let decoder = decoder else { return }
    guard index >= -1 && index < subtitleTracks.count else { return }
    guard index != selectedSubtitleTrackIndex else { return }

    // If disabling (-1), just clear state
    if index == -1 {
      _ = await decoder.switchSubtitleTrack(to: -1)
      selectedSubtitleTrackIndex = -1
      currentSubtitle = nil
      subtitles.removeAll()
      return
    }

    let track = subtitleTracks[index]

    // Switch track in decoder
    // Note: We don't necessarily need to seek if we just want to start showing from now,
    // but seeking ensures we get the current subtitle if we are in the middle of one.
    // For now, let's just switch lightly without full seek-reset cycle unless needed.

    let success = await decoder.switchSubtitleTrack(to: track.streamIndex)
    if success {
      selectedSubtitleTrackIndex = index
      // Clear old subtitles
      subtitles.removeAll()
      currentSubtitle = nil
    }
  }

  nonisolated deinit {
    cancelLocalTasks()
  }

  private func refreshDebugStats(videoPTS: Double? = nil) async {
    if let videoPTS = videoPTS {
      lastVideoPTS = videoPTS
    }

    let now = ProcessInfo.processInfo.systemUptime
    if now - lastStatsUpdateTime < 0.2 {
      return
    }
    lastStatsUpdateTime = now

    let queueCount = await packetQueue.count
    let queueMax = packetQueue.maxSize
    let videoReady = (renderer as? SampleBufferRenderer)?.isReadyForMoreMediaData ?? false
    let audioReady = audioOutput.isReadyForMoreMediaData
    let audioBackend: String = (audioOutput is SystemAudioRenderer) ? "System" : "AudioEngine"
    let syncRate = await playbackClock.rate
    let decoderName = decoder?.videoInfo.decoderName ?? "Unknown"
    let isHardwareDecoded = decoder?.videoInfo.isHardwareAccelerated ?? false

    debugStats.packetQueueCount = queueCount
    debugStats.packetQueueMax = queueMax
    debugStats.videoRendererReady = videoReady
    debugStats.audioRendererReady = audioReady
    debugStats.audioBackend = audioBackend
    debugStats.lastVideoPTS = lastVideoPTS
    debugStats.syncRate = syncRate
    debugStats.decoderName = decoderName
    debugStats.isHardwareDecoded = isHardwareDecoded
  }
}

// MARK: - Playback Worker Delegate

extension VideoPlayer: PlaybackWorkerDelegate {
  func workerDidRenderVideoFrame(_ frame: VideoFrame) {
    currentFrame = frame
  }

  func workerDidDecodeSubtitle(_ subtitle: SubtitleFrame) {
    subtitles.append(subtitle)
    // Keep only recent subtitles (e.g. last 100)
    if subtitles.count > 100 {
      subtitles.removeFirst()
    }
  }

  func workerDidDetectAudio() {
    hasAudio = true
  }

  func workerDidFinishStream() {
    guard state == .playing else { return }
    state = .finished
    Task { await playbackClock.pause() }
    Task { await audioOutput.flush() }
  }

  func workerRefreshDebugStats(videoPTS: Double?) async {
    await refreshDebugStats(videoPTS: videoPTS)
  }
}

// MARK: - Seek/Scrub Coordinator

private actor SeekCoordinator {
  private weak var player: VideoPlayer?
  private var activeSeekTask: Task<Void, Never>?
  private var scrubTask: Task<Void, Never>?
  private var scrubContinuation: AsyncStream<Double>.Continuation?
  private var latestScrubTime: Double?
  private var isScrubbing = false

  init(player: VideoPlayer) {
    self.player = player
  }

  func cancelAll() async {
    scrubContinuation?.finish()
    scrubContinuation = nil

    scrubTask?.cancel()
    _ = await scrubTask?.result
    scrubTask = nil

    activeSeekTask?.cancel()
    _ = await activeSeekTask?.result
    activeSeekTask = nil

    latestScrubTime = nil
    isScrubbing = false
  }

  func seek(to seconds: Double) async {
    await cancelScrubIfNeeded()
    await cancelActiveSeek()

    guard let player = player else { return }
    activeSeekTask = Task { [weak player] in
      await player?.performSeek(to: seconds, resumePlayback: nil)
    }
    await activeSeekTask?.value
    activeSeekTask = nil
  }

  func beginScrub() async {
    await cancelActiveSeek()
    await cancelScrubIfNeeded()

    guard let player = player else { return }
    _ = await player.prepareForScrub()

    isScrubbing = true
    latestScrubTime = nil

    let (stream, continuation) = AsyncStream<Double>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    scrubContinuation = continuation

    scrubTask = Task { [weak player] in
      for await targetTime in stream {
        guard !Task.isCancelled else { break }
        await player?.performScrubSeek(to: targetTime)
      }
    }
  }

  func scrub(to time: Double) async {
    guard let player = player else { return }
    let duration = await player.snapshotDuration()
    let clamped = max(0, min(time, duration))

    guard isScrubbing else {
      await seek(to: clamped)
      return
    }

    latestScrubTime = clamped
    scrubContinuation?.yield(clamped)
  }

  func endScrub(resumePlayback: Bool) async {
    guard isScrubbing else { return }
    isScrubbing = false

    scrubContinuation?.finish()
    scrubContinuation = nil
    scrubTask?.cancel()
    _ = await scrubTask?.result
    scrubTask = nil

    guard let player = player else { return }
    let finalTime: Double
    if let latestScrubTime {
      finalTime = latestScrubTime
    } else {
      finalTime = await player.snapshotCurrentTime()
    }
    latestScrubTime = nil

    await player.finishScrub(at: finalTime, resumePlayback: resumePlayback)
  }

  private func cancelScrubIfNeeded() async {
    guard isScrubbing else { return }
    scrubContinuation?.finish()
    scrubContinuation = nil
    scrubTask?.cancel()
    _ = await scrubTask?.result
    scrubTask = nil
    latestScrubTime = nil
    isScrubbing = false
  }

  private func cancelActiveSeek() async {
    activeSeekTask?.cancel()
    _ = await activeSeekTask?.result
    activeSeekTask = nil
  }
}

/// Real-time debug statistics for the video player
public struct PlayerDebugStats: Sendable {
  public var packetQueueCount: Int = 0
  public var packetQueueMax: Int = 0
  public var videoRendererReady: Bool = false
  public var audioRendererReady: Bool = false
  public var audioBackend: String = "Unknown"
  public var lastVideoPTS: Double = 0
  public var isHardwareDecoded: Bool = false
  public var decoderName: String = "Unknown"
  public var syncRate: Double = 0.0
  public var keyframeCount: Int = 0
}
