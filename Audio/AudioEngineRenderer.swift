//
//  AudioEngineRenderer.swift
//  VidCore
//
//  Fallback audio output for app extensions (e.g., Quick Look).
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

      // Best-effort for Quick Look: queue buffers sequentially without explicit timing.
      self.playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)

      if self.pendingPlay && !self.isPlaying {
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
    }
  }

  public func setPlaybackState(isPlaying: Bool, rate: Double) {
    enqueueQueue.async { [weak self] in
      guard let self else { return }
      self.pendingPlay = isPlaying
      self.timePitch.rate = Float(max(0.25, min(rate, 4.0)))
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
}
