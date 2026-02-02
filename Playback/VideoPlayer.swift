//
//  VideoPlayer.swift
//  VidCore
//
//  High-level video player with playback orchestration
//
//  Decoupled Architecture:
//  - VideoPlayer (MainActor): Orchestrates high-level state, user input, and UI/Debug mirroring.
//  - VideoDisplayLoop (Actor): Runs the display loop on a background thread, pushing frames to renderer.
//

import Foundation
import Observation
import QuartzCore

// MARK: - Timing Constants
private enum PlaybackTiming {
  static let seekPauseDelay: UInt64 = 50_000_000  // 50ms
}

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
  public var volume: Double = 1.0 {
    didSet { audioPlayer.volume = Float(volume) }
  }

  /// Playback rate (0.25 to 3.0 recommended)
  public var playbackRate: Double = 1.0 {
    didSet {
      let clamped = max(0.1, min(playbackRate, 32.0))
      audioPlayer.rate = Float(clamped)
      Task {
        await displayLoop.setRate(clamped)
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

  private let audioPlayer = AudioPlayer()
  private var decoder: VideoDecoder?
  private var frameBuffer: VideoFrameBuffer
  private var packetQueue: PacketQueue
  private var buffers: Buffers

  // Decoupled Display Loop
  private let displayLoop: VideoDisplayLoop

  // Task management
  nonisolated(unsafe) private var demuxTask: Task<Void, Never>?
  nonisolated(unsafe) private var decodeTask: Task<Void, Never>?
  nonisolated(unsafe) private var currentSeekTask: Task<Void, Never>?

  private var subtitles: [SubtitleFrame] = []

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
    let frameBufferSize = buffers.frameBufferSize
    let packetQueueSize = buffers.packetQueueSize

    let frameBuffer = VideoFrameBuffer(maxSize: frameBufferSize)
    let packetQueue = PacketQueue(maxSize: packetQueueSize)
    self.frameBuffer = frameBuffer
    self.packetQueue = packetQueue
    self.displayLoop = VideoDisplayLoop(
      frameBuffer: frameBuffer, packetQueue: packetQueue, audioPlayer: audioPlayer)

    setupCallbacks()
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
      print("[VideoPlayer] Using explicit buffer config: \(buffers)")
    }

    print(
      "[VideoPlayer] Buffer sizes: frameBuffer=\(effectiveBuffers.frameBufferSize), packetQueue=\(effectiveBuffers.packetQueueSize)"
    )
    self.init(buffers: effectiveBuffers)
  }

  private func setupCallbacks() {
    Task {
      await displayLoop.setStatsHandler { [weak self] stats in
        guard let self = self else { return }
        var updatedStats = stats
        updatedStats.keyframeCount = self.decoder?.keyframeCount ?? 0
        self.debugStats = updatedStats
      }
      await displayLoop.setFrameUpdateHandler { [weak self] frame in
        guard let self = self else { return }
        self.currentFrame = frame  // Update mirror
        self.currentTime = frame.presentationTime
        self.updateSubtitles(for: frame.presentationTime)
      }
      await displayLoop.setCompletionHandler { [weak self] in
        guard let self = self else { return }
        if self.state == .playing {
          self.state = .finished
          // Ensure audio is paused so it doesn't try to continue or hold resources
          self.audioPlayer.pause()
        }
      }
    }
  }

  // MARK: - Public API

  /// Sets the target renderer for video frames.
  /// This connects the decoupled display loop to the screen.
  public func setRenderer(_ target: VideoRendererTarget?) async {
    await displayLoop.setRenderer(target)
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
      let currentFrameSize = await frameBuffer.maxSize
      let currentPacketSize = await packetQueue.maxSize
      let targetFrameSize = targetBuffer.frameBufferSize
      let targetPacketSize = targetBuffer.packetQueueSize

      if currentFrameSize != targetFrameSize || currentPacketSize != targetPacketSize {
        print(
          "[VideoPlayer] Resizing buffers for \(isHardware ? "hardware" : "software") decoding: frameBuffer \(currentFrameSize)->\(targetFrameSize), packetQueue \(currentPacketSize)->\(targetPacketSize)"
        )

        // Recreate buffers with correct sizes
        await frameBuffer.reset()
        await packetQueue.reset()

        frameBuffer = VideoFrameBuffer(maxSize: targetFrameSize)
        packetQueue = PacketQueue(maxSize: targetPacketSize)

        // Update displayLoop with new buffers
        await displayLoop.updateBuffers(frameBuffer: frameBuffer, packetQueue: packetQueue)
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

        await displayLoop.setVideoInfo(decoder.videoInfo)

        // Start background generation of keyframe index for accurate seeking
        decoder.startKeyframeIndexing()

        while !Task.isCancelled {
          guard let packet = await decoder.demuxNextPacket() else { break }
          let frames = await decoder.decodePacket(packet)
          if let videoFrame = frames.compactMap({ frame -> VideoFrame? in
            if case .video(let vf) = frame { return vf }
            return nil
          }).first {
            currentFrame = videoFrame
            // Push initial frame to buffer so loop picks it up immediately
            await frameBuffer.push(videoFrame)
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
      print("[VideoPlayer] Play called in .finished state. Restarting...")
      Task {
        await seek(to: 0)
        await packetQueue.resume()
        await frameBuffer.resume()
        state = .ready
        print("[VideoPlayer] State unset to .ready, calling play()")
        play()
      }
      return
    }

    if state == .paused {
      print("[VideoPlayer] Play called in .paused state. Resuming...")
      state = .playing
      audioPlayer.play()
      Task {
        await displayLoop.start()
      }

      Task {
        await packetQueue.resume()
        await frameBuffer.resume()
      }

      startTasks()
      return
    }

    print("[VideoPlayer] Play called. Starting from fresh.")
    state = .playing
    audioPlayer.play()
    Task {
      await displayLoop.start()
    }

    startTasks()
  }

  /// Pause playback.
  public func pause() {
    guard state == .playing else { return }

    state = .paused
    audioPlayer.pause()
    Task {
      await displayLoop.pause()
    }

    Task {
      await packetQueue.suspend()
      await frameBuffer.suspend()
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
  ///   - accurate: If true, seeks to exact frame; if false, seeks to nearest keyframe.
  public func seek(to seconds: Double, accurate: Bool = true) async {
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
      audioPlayer.pause()

      await displayLoop.pause()
      await packetQueue.suspend()
      await frameBuffer.suspend()

      guard !Task.isCancelled else {
        // Restore previous state if cancelled
        state = previousState
        if wasPlaying {
          audioPlayer.play()
          await displayLoop.start()
          await packetQueue.resume()
          await frameBuffer.resume()
        }
        return
      }

      await packetQueue.reset()
      await frameBuffer.reset()
      subtitles.removeAll()
      currentSubtitle = nil
      await displayLoop.reset()  // Ensure loop state is clean

      do {
        if let seekFrame = try await decoder.seek(to: clampedSeconds, accurate: accurate) {
          guard !Task.isCancelled else { return }
          currentFrame = seekFrame
          // Force display the frame immediately since loop might be paused
          await displayLoop.displayFrame(seekFrame)

          // Push the seek frame to buffer so it flows into the display loop when playing
          await frameBuffer.push(seekFrame)

          // Update timing to match the actual frame found
          currentTime = seekFrame.presentationTime
        } else {
          guard !Task.isCancelled else { return }
          // Fallback if no frame returned (should catch in error)
          currentTime = clampedSeconds
        }

        audioPlayer.seek(to: currentTime)

        guard !Task.isCancelled else {
          return
        }

        // 2. Restart tasks now that seek is complete and queues are clean
        self.startTasks()

        if wasPlaying {
          state = .playing
          audioPlayer.play()
          await displayLoop.start()
          await packetQueue.resume()
          await frameBuffer.resume()
        } else {
          // We already have the frame displayed, so just pause
          await packetQueue.suspend()
          await frameBuffer.suspend()
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

    audioPlayer.cleanup()

    await stopTasks()
    await displayLoop.stop()

    currentSeekTask?.cancel()
    currentSeekTask = nil

    await packetQueue.reset()
    await frameBuffer.reset()

    decoder?.close()
    decoder = nil

    currentFrame = nil
    currentSubtitle = nil
    subtitles.removeAll()

    state = .idle
  }

  private func updateSubtitles(for time: Double) {
    // Find the subtitle that matches current time
    // Use last (most recent) to ensure newer subtitles replace older overlapping ones
    let newSubtitle = subtitles.last { sub in
      time >= sub.startTime && (sub.endTime == nil || time <= sub.endTime!)
    }

    // Only update if changed (to avoid excessive view updates, though SwiftUI handles it)
    // using startTime as identity for now
    if newSubtitle?.startTime != currentSubtitle?.startTime {
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
          await frameBuffer.pushWithBackpressure(frame)
          drainedCount += 1
        }

        await frameBuffer.close()
        break
      }

      guard !Task.isCancelled else { break }

      let decodedFrames = await decoder.decodePacket(packet)
      for frame in decodedFrames {
        switch frame {
        case .video(let videoFrame):
          await frameBuffer.pushWithBackpressure(videoFrame)
        case .audio(let buffer, let pts):
          await MainActor.run {
            hasAudio = true
            audioPlayer.enqueue(buffer, pts: pts)
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
  }

  /// Synchronous close for use from deinit or when async cannot be awaited.
  public nonisolated func closeSync() {
    cancelAllTasks()

    if Thread.isMainThread {
      MainActor.assumeIsolated {
        if isPlaying {
          pause()
        }

        audioPlayer.cleanup()
        decoder?.close()
        decoder = nil
        currentFrame = nil

        Task {
          await displayLoop.stop()
        }

        demuxTask = nil
        decodeTask = nil
        currentSeekTask = nil

        state = .idle

        let pq = packetQueue
        let fb = frameBuffer
        Task.detached(priority: .high) {
          await pq.reset()
          await fb.reset()
        }
      }
    } else {
      DispatchQueue.main.sync {
        MainActor.assumeIsolated {
          if isPlaying {
            pause()
          }

          audioPlayer.cleanup()
          decoder?.close()
          decoder = nil
          currentFrame = nil

          Task {
            await displayLoop.stop()
          }

          demuxTask = nil
          decodeTask = nil
          currentSeekTask = nil

          state = .idle

          let pq = packetQueue
          let fb = frameBuffer
          Task.detached(priority: .high) {
            await pq.reset()
            await fb.reset()
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
    await seek(to: currentPosition, accurate: true)

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
}

/// Real-time debug statistics for the video player
public struct PlayerDebugStats: Sendable {
  public var packetQueueCount: Int = 0
  public var packetQueueMax: Int = 0
  public var frameBufferCount: Int = 0
  public var frameBufferMax: Int = 0
  public var avDrift: Double = 0.0
  public var droppedFrameCount: Int = 0
  public var isHardwareDecoded: Bool = false
  public var decoderName: String = "Unknown"
  public var displayRefreshRate: Double = 0.0
  public var keyframeCount: Int = 0
}
