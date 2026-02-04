//
//  AudioEngineRenderer.swift
//  VidCore
//
//  PTS-based audio output for app extensions (e.g., Quick Look).
//

import AVFoundation
import Foundation

public final class AudioEngineRenderer: AudioRendering, @unchecked Sendable {
  public let isEnabled: Bool = true

  private let engine = AVAudioEngine()
  private let playerNode = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private let enqueueQueue = DispatchQueue(label: "VidCore.AudioEngineRenderer")
  private var configuredFormat: AVAudioFormat?
  private var isPlaying: Bool = false
  private var pendingPlay: Bool = false

  // Buffer queue management for pre-roll and smooth playback
  private var enqueuedBufferCount: Int = 0
  private let minimumBufferCount: Int = 3
  private let bufferCountLock = NSLock()

  public init() {
    engine.attach(playerNode)
    engine.attach(timePitch)
    timePitch.rate = 1.0
    engine.connect(playerNode, to: timePitch, format: nil)
    engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
    startEngineIfNeeded()
  }

  public var isReadyForMoreMediaData: Bool {
    // AVAudioPlayerNode has no explicit backpressure; accept buffers freely.
    true
  }

  public func waitUntilReady() async {
    // No backpressure; always ready.
  }

  public func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float) {
    enqueueQueue.async { [weak self] in
      guard let self else { return }
      self.configureIfNeeded(for: buffer.format)
      self.startEngineIfNeeded()
      self.playerNode.volume = max(0.0, min(volume, 1.0))

      // Schedule immediately - AVAudioEngine handles timing
      self.playerNode.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
        self?.bufferCountLock.lock()
        self?.enqueuedBufferCount -= 1
        self?.bufferCountLock.unlock()
      }

      self.bufferCountLock.lock()
      self.enqueuedBufferCount += 1
      let count = self.enqueuedBufferCount
      self.bufferCountLock.unlock()

      // Start playback once we have minimum buffers
      if self.pendingPlay && !self.isPlaying && count >= self.minimumBufferCount {
        self.playerNode.play()
        self.isPlaying = true
      }
    }
  }

  public func flush() {
    enqueueQueue.sync {
      playerNode.stop()
      playerNode.reset()
      isPlaying = false
      pendingPlay = false
      // Reset buffer count
      bufferCountLock.lock()
      enqueuedBufferCount = 0
      bufferCountLock.unlock()
    }
  }

  public func setPlaybackState(isPlaying: Bool, rate: Double) {
    enqueueQueue.async { [weak self] in
      guard let self else { return }
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
