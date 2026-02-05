//
//  AudioEngineRenderer.swift
//  VidCore
//
//  PTS-based audio output for app extensions (e.g., Quick Look).
//

import AVFoundation
import Foundation

public actor AudioEngineRenderer: AudioRendering {
  public nonisolated let isEnabled: Bool = true

  nonisolated private let engine = AVAudioEngine()
  nonisolated private let playerNode = AVAudioPlayerNode()
  nonisolated private let timePitch = AVAudioUnitTimePitch()
  private var configuredFormat: AVAudioFormat?
  private var isPlaying: Bool = false
  private var pendingPlay: Bool = false

  // Buffer queue management for pre-roll and smooth playback
  private var enqueuedBufferCount: Int = 0
  private let minimumBufferCount: Int = 3

  public init() {
    engine.attach(playerNode)
    engine.attach(timePitch)
    timePitch.rate = 1.0
    engine.connect(playerNode, to: timePitch, format: nil)
    engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    startEngineIfNeeded()
  }

  public nonisolated var isReadyForMoreMediaData: Bool {
    // AVAudioPlayerNode has no explicit backpressure; accept buffers freely.
    true
  }

  public func waitUntilReady() async {
    // No backpressure; always ready.
  }

  public nonisolated func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float) {
    Task {
      await _enqueue(buffer, pts: pts, volume: volume)
    }
  }

  private func _enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float) {
    configureIfNeeded(for: buffer.format)
    startEngineIfNeeded()
    playerNode.volume = max(0.0, min(volume, 1.0))

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
    }
  }

  private func decrementBufferCount() {
    enqueuedBufferCount -= 1
  }

  public nonisolated func flush() {
    Task {
      await _flush()
    }
  }

  private func _flush() {
    playerNode.stop()
    playerNode.reset()
    isPlaying = false
    pendingPlay = false
    enqueuedBufferCount = 0
  }

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
      self.playerNode.play()
      self.isPlaying = true
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

  private func startEngineIfNeeded() {
    if engine.isRunning { return }
    do {
      try engine.start()
    } catch {
      print("[AudioEngineRenderer] Failed to start audio engine: \(error)")
    }
  }

  private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.commonFormat == rhs.commonFormat
      && lhs.isInterleaved == rhs.isInterleaved
  }

  /// Returns the PTS currently being played, if available.
  /// AudioEngineRenderer doesn't track precise PTS - this is a fallback renderer.
  public func currentPlaybackPTS() -> Double? {
    return nil
  }
}
