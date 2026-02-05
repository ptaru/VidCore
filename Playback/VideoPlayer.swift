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

  // MARK: - Volume Control

  /// Playback volume (0.0 to 1.0)
  public var volume: Double = 1.0

  /// Playback rate (0.25 to 3.0 recommended)
  public var playbackRate: Double = 1.0 {
    didSet {
      let clamped = max(0.1, min(playbackRate, 32.0))
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
  nonisolated(unsafe) private var demuxTask: Task<Void, Never>?
  @ObservationIgnored
  nonisolated(unsafe) private var decodeTask: Task<Void, Never>?
  @ObservationIgnored
  nonisolated(unsafe) private var currentSeekTask: Task<Void, Never>?
  @ObservationIgnored
  nonisolated(unsafe) private var scrubTask: Task<Void, Never>?
  @ObservationIgnored
  nonisolated(unsafe) private var scrubContinuation: AsyncStream<Double>.Continuation?

  private var subtitles: [SubtitleFrame] = []
  private var lastSubtitleUpdateTime: Double = 0

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
      }
    }

    do {
      decoder = try VideoDecoder(url: url)
      if let decoder = decoder {

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

        while !Task.isCancelled {
          guard let packet = await decoder.demuxNextPacket() else { break }
          let frames = await decoder.decodePacket(packet)
          if let videoFrame = frames.compactMap({ frame -> VideoFrame? in
            if case .video(let vf) = frame { return vf }
            return nil
          }).first {
            currentFrame = videoFrame
            await renderer?.enqueue(videoFrame)
            if state == .playing {
              currentTime = await playbackClock.getCurrentTime()
            } else {
              currentTime = videoFrame.presentationTime
              await playbackClock.seek(to: videoFrame.presentationTime)
            }
            await refreshDebugStats(videoPTS: videoFrame.presentationTime)
            break
          }
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
      Task { await playbackClock.play(rate: playbackRate) }
      audioOutput.setPlaybackState(isPlaying: true, rate: playbackRate)

      Task {
        await packetQueue.resume()
      }

      startTasks()
      return
    }

    // Debug logging removed: noisy in Quick Look extensions.
    state = .playing
    Task { await playbackClock.play(rate: playbackRate) }
    audioOutput.setPlaybackState(isPlaying: true, rate: playbackRate)

    startTasks()
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
    currentSeekTask?.cancel()

    let task = Task { @MainActor [weak self] in
      guard let self = self, let decoder = decoder else { return }

      // 1. Stop background tasks to prevent resource contention and race conditions
      await self.stopTasks()

      guard !Task.isCancelled else { return }

      let clampedSeconds = max(0, min(seconds, duration))
      let wasPlaying = state == .playing
      let previousState = state

      // Enter seeking state to prevent race conditions
      state = .seeking
      await playbackClock.pause()
      audioOutput.setPlaybackState(isPlaying: false, rate: playbackRate)
      await packetQueue.suspend()

      guard !Task.isCancelled else {
        // Restore previous state if cancelled
        state = previousState
        if wasPlaying {
          await playbackClock.play(rate: playbackRate)
          await packetQueue.resume()
        }
        return
      }

      await packetQueue.reset()
      subtitles.removeAll()
      currentSubtitle = nil
      lastSubtitleUpdateTime = 0
      if let sbRenderer = renderer as? SampleBufferRenderer {
        sbRenderer.flush()
      }

      do {
        if let seekFrame = try await decoder.seek(to: clampedSeconds) {
          guard !Task.isCancelled else { return }
          currentFrame = seekFrame
          await playbackClock.seek(to: seekFrame.presentationTime)
          await renderer?.enqueue(seekFrame)

          // Update timing to match the actual frame found
          currentTime = seekFrame.presentationTime
        } else {
          guard !Task.isCancelled else { return }
          // Fallback if no frame returned (should catch in error)
          currentTime = clampedSeconds
        }

        await audioOutput.flush()

        guard !Task.isCancelled else {
          return
        }

        // 2. Restart tasks now that seek is complete and queues are clean
        self.startTasks()

        if wasPlaying {
          state = .playing
          await playbackClock.play(rate: playbackRate)
          audioOutput.setPlaybackState(isPlaying: true, rate: playbackRate)
          await packetQueue.resume()
        } else {
          // We already have the frame displayed, so just pause
          await packetQueue.suspend()
          state = .paused
        }
      } catch {

        // Restore to paused state on error
        state = .paused
      }
    }

    currentSeekTask = task
    await task.value
  }

  /// Close the player and release resources.
  public func close() async {

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

    currentSeekTask?.cancel()
    currentSeekTask = nil

    await packetQueue.reset()

    decoder?.close()
    decoder = nil

    currentFrame = nil
    currentSubtitle = nil
    subtitles.removeAll()

    state = .idle
  }

  // MARK: - Scrubbing

  /// Begin a scrubbing session.
  ///
  /// This pauses playback, stops the decode loop, and prepares the player for rapid
  /// coalesced seeking. Use `scrub(to:)` to update the position.
  public func beginScrub() async {
    // Prevent re-entrancy
    // Move state transition to start to prevent race with scrub(to:)
    let previousState = state
    state = .scrubbing

    // Stop existing tasks
    await stopTasks()
    currentSeekTask?.cancel()

    await playbackClock.pause()
    audioOutput.setPlaybackState(isPlaying: false, rate: playbackRate)
    await packetQueue.suspend()

    // Create a stream for coalesced scrubbing updates
    // bufferingNewest(1) ensures we drop intermediate updates and only process the latest
    let (stream, continuation) = AsyncStream<Double>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    self.scrubContinuation = continuation

    // Start the dedicated scrub task
    scrubTask = Task { [weak self, stream] in
      guard let self = self else { return }

      for await targetTime in stream {
        guard !Task.isCancelled else { break }
        guard let decoder = await self.decoder else { continue }

        do {
          // Perform accurate seek
          // Note: VideoDecoder.seek is now always accurate
          if let frame = try await decoder.seek(to: targetTime) {
            let renderer = await MainActor.run {
              self.currentFrame = frame
              self.currentTime = frame.presentationTime
              self.updateSubtitles(for: frame.presentationTime)
              return self.renderer
            }

            if let r = renderer {
              if let sbRenderer = r as? SampleBufferRenderer {
                sbRenderer.flush()
              }
              await r.enqueue(frame)
            }
            await self.refreshDebugStats(videoPTS: frame.presentationTime)
          }
        } catch {
          print("[VideoPlayer] Scrub seek failed: \(error)")
        }
      }
    }
  }

  /// Update the scrub position.
  ///
  /// This method is lightweight and designed to be called frequently (e.g., from a slider drag).
  /// Updates are coalesced so that the decoder only processes the latest request.
  ///
  /// - Parameter time: The target time to scrub to.
  public func scrub(to time: Double) {
    guard state == .scrubbing else {
      // If not in scrubbing state, just do a one-off seek (less efficient for dragging)
      Task { await seek(to: time) }
      return
    }
    let clamped = max(0, min(time, duration))
    scrubContinuation?.yield(clamped)
  }

  /// End the scrubbing session.
  ///
  /// - Parameter resumePlayback: Whether to resume playback after scrubbing ends.
  public func endScrub(resumePlayback: Bool) async {
    guard state == .scrubbing else { return }

    // Stop scrub task
    scrubContinuation?.finish()
    scrubContinuation = nil
    scrubTask?.cancel()
    _ = await scrubTask?.result
    scrubTask = nil

    // Resume normal operation
    // We are already at the correct frame from the last scrub update

    // Sync clock to the new position
    // Use MainActor to safely read the final scrub time
    let resumeTime = await MainActor.run { self.currentTime }
    await playbackClock.seek(to: resumeTime)
    await audioOutput.flush()

    // Restart the pipeline
    // Reset queue to clear old packets from before scrub
    // This is CRITICAL: otherwise the decoder processes old frames and video appears stuck
    await packetQueue.reset()
    startTasks()

    if resumePlayback {
      state = .playing
      await playbackClock.play(rate: playbackRate)
      audioOutput.setPlaybackState(isPlaying: true, rate: playbackRate)
    } else {
      state = .paused
      // Re-suspend if staying paused
      await packetQueue.suspend()
    }
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
    let newSubtitle = subtitles.last { sub in
      time >= sub.startTime && (sub.endTime == nil || time <= sub.endTime!)
    }

    // Only update if changed to avoid excessive SwiftUI view updates and flickering
    if newSubtitle != currentSubtitle {
      currentSubtitle = newSubtitle
    }
  }

  // MARK: - Task Management

  private func startTasks() {
    // Only start if not already running
    if demuxTask == nil {
      demuxTask = Task { [weak self] in
        await self?.runDemuxLoop()
      }
    }

    if decodeTask == nil {
      decodeTask = Task { [weak self] in
        await self?.runDecodeLoop()
      }
    }
  }

  private func stopTasks() async {
    demuxTask?.cancel()
    decodeTask?.cancel()

    // Deadlock Fix: Packets might be stuck pushing to a full queue.
    // We must suspend the queue to wake up any blocked producers/consumers
    // so they can check cancellation and exit.
    await packetQueue.suspend()

    // Display loop is controlled separately

    await demuxTask?.value
    await decodeTask?.value

    demuxTask = nil
    decodeTask = nil
  }

  // MARK: - Demux Loop

  private func runDemuxLoop() async {
    guard let decoder = decoder else { return }

    while !Task.isCancelled {
      if await packetQueue.suspended {
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        continue
      }

      guard let packet = await decoder.demuxNextPacket() else {
        await packetQueue.close()
        break
      }

      await packetQueue.push(packet)
    }
  }

  // MARK: - Decode Loop

  private func runDecodeLoop() async {
    guard let decoder = decoder else { return }

    while !Task.isCancelled {
      if await packetQueue.suspended {
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        continue
      }

      guard let packet = await packetQueue.pop() else {
        if await packetQueue.suspended {
          continue
        }

        await decoder.flushVideoDecoder()

        var drainedCount = 0
        while !Task.isCancelled {
          guard let frame = await decoder.drainVideoFrame() else {
            break
          }
          if let readinessAwaiter = renderer as? MediaDataReadinessAwaiting {
            await readinessAwaiter.waitUntilReady()
          }
          guard !Task.isCancelled else { break }
          await renderer?.enqueue(frame)
          currentFrame = frame
          currentTime = await playbackClock.getCurrentTime()
          updateSubtitles(for: currentTime)
          await refreshDebugStats(videoPTS: frame.presentationTime)
          drainedCount += 1
        }

        if state == .playing {
          state = .finished
          await playbackClock.pause()
          await audioOutput.flush()
        }
        break
      }

      guard !Task.isCancelled else { break }

      let decodedFrames = await decoder.decodePacket(packet)
      for frame in decodedFrames {
        switch frame {
        case .video(let videoFrame):
          if let readinessAwaiter = renderer as? MediaDataReadinessAwaiting {
            await readinessAwaiter.waitUntilReady()
          }
          guard !Task.isCancelled else { break }
          await renderer?.enqueue(videoFrame)
          currentFrame = videoFrame
          currentTime = await playbackClock.getCurrentTime()
          updateSubtitles(for: currentTime)
          await refreshDebugStats(videoPTS: videoFrame.presentationTime)
        case .audio(let buffer, let pts):
          guard audioOutput.isEnabled else { break }
          await audioOutput.waitUntilReady()
          if !Task.isCancelled {
            audioOutput.enqueue(buffer, pts: pts, volume: Float(volume))
            hasAudio = true
            await refreshDebugStats()
          }
        case .subtitle(let subtitleFrame):
          await MainActor.run {
            self.subtitles.append(subtitleFrame)
            // Keep only recent subtitles (e.g. last 100)
            if self.subtitles.count > 100 {
              self.subtitles.removeFirst()
            }
          }
        }
      }
    }
  }

  // MARK: - Cleanup

  /// Synchronously cancel all background tasks.
  public nonisolated func cancelAllTasks() {
    demuxTask?.cancel()
    decodeTask?.cancel()
    currentSeekTask?.cancel()
    scrubContinuation?.finish()
    scrubTask?.cancel()
  }

  /// Synchronous close for use from deinit or when async cannot be awaited.
  public nonisolated func closeSync() {
    cancelAllTasks()

    if Thread.isMainThread {
      MainActor.assumeIsolated {
        if isPlaying {
          pause()
        }

        Task { await audioOutput.flush() }
        decoder?.close()
        decoder = nil
        currentFrame = nil

        Task { await playbackClock.pause() }
        if let sbRenderer = renderer as? SampleBufferRenderer {
          sbRenderer.flush()
        }

        demuxTask = nil
        decodeTask = nil
        currentSeekTask = nil

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

          Task { await audioOutput.flush() }
          decoder?.close()
          decoder = nil
          currentFrame = nil

          Task { await playbackClock.pause() }
          if let sbRenderer = renderer as? SampleBufferRenderer {
            sbRenderer.flush()
          }

          demuxTask = nil
          decodeTask = nil
          currentSeekTask = nil

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
    cancelAllTasks()
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
