//
//  AudioEngineRenderer.swift
//  VidCore
//
//  PTS-based audio output for app extensions (e.g., Quick Look).
//

import AVFoundation
import Foundation

public actor AudioEngineRenderer: AudioRendering {
  /// Whether this renderer is enabled and functional.
  public nonisolated let isEnabled: Bool = true

  nonisolated private let engine = AVAudioEngine()
  nonisolated private let playerNode = AVAudioPlayerNode()
  nonisolated private let timePitch = AVAudioUnitTimePitch()
  private var configuredFormat: AVAudioFormat?
  private var isPlaying: Bool = false
  private var pendingPlay: Bool = false

  // PTS tracking for synchronization
  private var startPTS: Double?
  private var firstEnqueuedPTS: Double?
  private var lastEnqueuedPTS: Double?

  // Buffer queue management for pre-roll and smooth playback
  private var enqueuedBufferCount: Int = 0
  private let minimumBufferCount: Int = 3

  /// Creates a new audio engine renderer.
  public init() {
    engine.attach(playerNode)
    engine.attach(timePitch)
    timePitch.rate = 1.0
    engine.connect(playerNode, to: timePitch, format: nil)
    engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    startEngineIfNeeded()
  }

  /// Whether the renderer is ready to accept more audio data.
  public nonisolated var isReadyForMoreMediaData: Bool {
    // AVAudioPlayerNode has no explicit backpressure; accept buffers freely.
    true
  }

  /// Waits until the renderer is ready for more data.
  public func waitUntilReady() async -> Bool {
    // No backpressure; always ready.
    return true
  }

  /// Sets the audio volume.
  /// - Parameter volume: The volume level (0.0 to 1.0).
  public nonisolated func setVolume(_ volume: Float) {
    Task { await _setVolume(volume) }
  }

  /// Enqueues an audio buffer for playback.
  /// - Parameters:
  ///   - buffer: The PCM buffer containing audio data.
  ///   - pts: The presentation timestamp in seconds.
  ///   - volume: The volume level for this buffer.
  public nonisolated func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float) {
    Task {
      await _enqueue(buffer, pts: pts, volume: volume)
    }
  }

  private func _setVolume(_ volume: Float) {
    playerNode.volume = max(0.0, min(volume, 1.0))
  }

  private func decrementBufferCount() {
    enqueuedBufferCount -= 1
    if enqueuedBufferCount == 0 {
      // If buffer runs dry, timing may drift until next flush/seek.
      // Resetting is deferred to avoid audio glitches.
    }
  }

  private func _enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float) {
    configureIfNeeded(for: buffer.format)
    startEngineIfNeeded()
    playerNode.volume = max(0.0, min(volume, 1.0))
    lastEnqueuedPTS = pts
    if firstEnqueuedPTS == nil {
      firstEnqueuedPTS = pts
    }

    // Schedule immediately - AVAudioEngine handles timing
    playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
      guard let self else { return }
      Task {
        await self.decrementBufferCount()
      }
    }

    enqueuedBufferCount += 1
    let count = enqueuedBufferCount

    // Start playback once we have minimum buffers
    if pendingPlay && !isPlaying && count >= minimumBufferCount {
      playerNode.play()
      isPlaying = true

      // Record start timing for synchronization
      // Use the PTS of the VERY FIRST buffer we enqueued as the base.
      self.startPTS = firstEnqueuedPTS
    }
  }

  /// Flushes the audio renderer.
  public func flush() async {
    // Stop player node immediately (thread-safe)
    playerNode.stop()
    playerNode.reset()

    // Reset state directly on actor (safe because we are isolated)
    isPlaying = false
    pendingPlay = false
    enqueuedBufferCount = 0
    startPTS = nil
    firstEnqueuedPTS = nil
    lastEnqueuedPTS = nil
  }

  /// Updates the playback state.
  /// - Parameters:
  ///   - isPlaying: Whether playback should be active.
  ///   - rate: The playback rate.
  public nonisolated func setPlaybackState(isPlaying: Bool, rate: Double) {
    Task {
      await _setPlaybackState(isPlaying: isPlaying, rate: rate)
    }
  }

  private func _setPlaybackState(isPlaying: Bool, rate: Double) {
    self.pendingPlay = isPlaying
    let clampedRate = max(0.25, min(rate, 4.0))
    self.timePitch.rate = Float(clampedRate)
    self.startEngineIfNeeded()

    if isPlaying && self.configuredFormat != nil && !self.isPlaying {
      // Only start node if we have enough buffers, or if we were already in a stream (resuming)
      if enqueuedBufferCount >= minimumBufferCount || startPTS != nil {
        self.playerNode.play()
        self.isPlaying = true
      }
    } else if !isPlaying && self.isPlaying {
      self.playerNode.pause()
      self.isPlaying = false
    }
  }

  private func configureIfNeeded(for format: AVAudioFormat) {
    if let configured = configuredFormat, formatsMatch(configured, format) {
      return
    }

    engine.stop()
    playerNode.stop()
    playerNode.reset()
    engine.disconnectNodeOutput(playerNode)
    engine.disconnectNodeOutput(timePitch)
    engine.connect(playerNode, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    configuredFormat = format
    startEngineIfNeeded()
    if pendingPlay {
      playerNode.play()
      isPlaying = true
    }
  }

  nonisolated private func startEngineIfNeeded() {
    if engine.isRunning { return }
    do {
      try engine.start()
    } catch {
    }
  }

  private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.commonFormat == rhs.commonFormat
      && lhs.isInterleaved == rhs.isInterleaved
  }

  /// Returns the PTS currently being played, if available.
  /// - Returns: The current playback PTS in seconds, or `nil` if unavailable.
  public func currentPlaybackPTS() async -> Double? {
    guard isPlaying, let startPTS = startPTS else {
      return nil
    }

    // playerTime(forNodeTime:) provides the most accurate "samples played" since play()
    guard let lastRenderTime = playerNode.lastRenderTime,
      let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime)
    else {
      return startPTS
    }

    let elapsedSeconds = Double(playerTime.sampleTime) / playerTime.sampleRate
    let currentPTS = startPTS + elapsedSeconds

    return currentPTS
  }
}
