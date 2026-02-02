//
//  VideoDisplayLoop.swift
//  VidCore
//
//  Decoupled display loop running on a background actor
//

import AVFoundation
import AppKit
import CoreVideo
import Foundation
import QuartzCore

/// Actor responsible for the video display loop.
/// It consumes frames from the buffer, synchronizes with audio, and pushes to the renderer.
public actor VideoDisplayLoop {

  // MARK: - Dependencies and state
  private var frameBuffer: VideoFrameBuffer
  private var packetQueue: PacketQueue
  private let audioPlayer: AudioPlayer
  private weak var renderer: VideoRendererTarget?

  private var isRunning = false
  private var displayLink: DisplayLinkDriver!

  // Playback State
  private var hasStarted = false
  private var droppedFrameCount = 0
  private var reachedEndOfStream = false

  // Timing state
  private var playbackStartTime: CFTimeInterval = 0
  private var pauseTimestamp: CFTimeInterval = 0
  private var firstFramePTS: Double = 0
  private var audioStartOffset: Double = 0

  // Cached info
  private var frameRate: Double = 30.0
  private var isHardware: Bool = false
  private var decoderName: String = "Unknown"

  // Sync state
  private var consecutiveDriftCount: Int = 0

  // Callback for debug stats
  private var statsUpdateHandler: (@MainActor @Sendable (PlayerDebugStats) -> Void)?
  private var frameUpdateHandler: (@MainActor @Sendable (VideoFrame) -> Void)?
  private var completionHandler: (@MainActor @Sendable () -> Void)?

  // Constants
  private enum Constants {
    static let displayLoopInterval: UInt64 = 8_000_000  // 8ms
    static let driftWarningThreshold: Double = 0.05  // 50ms
    static let driftCorrectionThreshold: Double = 0.15  // 150ms
    static let severeDriftThreshold: Double = 1.0  // 1s
    static let severeDriftCountThreshold: Int = 5
    static let consecutiveDriftCountThreshold: Int = 3
  }

  public init(frameBuffer: VideoFrameBuffer, packetQueue: PacketQueue, audioPlayer: AudioPlayer) {
    self.frameBuffer = frameBuffer
    self.packetQueue = packetQueue
    self.audioPlayer = audioPlayer

    Task { @MainActor [weak self] in
      let driver = DisplayLinkDriver { [weak self] in
        Task { [weak self] in
          await self?.processFrame()
        }
      }
      await self?.setDisplayLink(driver)
    }
  }

  private func setDisplayLink(_ driver: DisplayLinkDriver) {
    self.displayLink = driver
  }

  public func setRenderer(_ target: VideoRendererTarget?) {
    self.renderer = target
  }

  public func setVideoInfo(_ info: VideoInfo?) {
    self.frameRate = info?.frameRate ?? 30.0
    self.isHardware = info?.isHardwareAccelerated ?? false
    self.decoderName = info?.decoderName ?? "Unknown"
  }

  /// Update the frame buffer and packet queue references.
  /// Used when buffer sizes need to change (e.g., auto-detected hardware vs software).
  public func updateBuffers(frameBuffer: VideoFrameBuffer, packetQueue: PacketQueue) {
    self.frameBuffer = frameBuffer
    self.packetQueue = packetQueue
  }

  public func reset() {
    isRunning = false
    hasStarted = false
    droppedFrameCount = 0
    reachedEndOfStream = false
    let link = self.displayLink
    Task { @MainActor in
      link?.stop()
    }
    resetTiming()
  }

  /// Called when seeking to clear timing state
  /// Called when seeking to clear timing state
  public func resetTiming() {
    hasStarted = false
    consecutiveDriftCount = 0
  }

  public func setStatsHandler(_ handler: @escaping @MainActor @Sendable (PlayerDebugStats) -> Void)
  {
    self.statsUpdateHandler = handler
  }

  public func setFrameUpdateHandler(_ handler: @escaping @MainActor @Sendable (VideoFrame) -> Void)
  {
    self.frameUpdateHandler = handler
  }

  public func setCompletionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
    self.completionHandler = handler
  }

  // MARK: - Control

  public func start() {
    guard !isRunning else { return }
    isRunning = true
    let link = self.displayLink
    Task { @MainActor in
      link?.start()
    }
  }

  public func stop() {
    isRunning = false
    Task { @MainActor [weak self] in
      // Capture link safely if needed, but here we just need to stop it
      // Since displayLink is private to actor, we must access it carefully.
      // Actually, since DisplayLinkDriver is MainActor, we should have the actor
      // manage the reference but dispatch calls.
      // However, `displayLink` property access from inside the Task (closure)
      // is cross-actor if `self` is captured.
      // Best pattern: `let link = self.displayLink` (captured in actor context)
      // then use `link` in Task.
    }
    // Correct approach:
    let link = self.displayLink
    Task { @MainActor in
      link?.stop()
    }
  }

  public func pause() {
    stop()
  }

  /// Manually display a frame (e.g. after seeking while paused)
  public func displayFrame(_ frame: VideoFrame) {
    renderer?.enqueue(frame)

    // Fire frame update to mirror
    if let frameHandler = frameUpdateHandler {
      Task { @MainActor in
        frameHandler(frame)
      }
    }
  }

  // MARK: - Loop

  private func processFrame() async {
    guard isRunning else { return }
    if await frameBuffer.suspended { return }

    // Peek next frame
    guard let nextFrame = await frameBuffer.peek() else {
      // Buffer empty/starved
      return
    }

    if !hasStarted {
      playbackStartTime = CACurrentMediaTime()
      firstFramePTS = nextFrame.presentationTime
      hasStarted = true
    }

    // Calculate timing
    let currentPlaybackTime: Double
    if await audioPlayer.hasBufferedAudio && audioPlayer.isPlaying {
      currentPlaybackTime = audioPlayer.getMediaTime()
    } else {
      currentPlaybackTime = (CACurrentMediaTime() - playbackStartTime) + firstFramePTS
    }

    var waitTime = nextFrame.presentationTime - currentPlaybackTime

    // Sync Logic
    if await audioPlayer.hasBufferedAudio && audioPlayer.isPlaying {
      let drift = waitTime
      if abs(drift) > Constants.driftWarningThreshold {
        consecutiveDriftCount += 1
      } else {
        consecutiveDriftCount = 0
      }
    }

    // Wait or Drop
    if waitTime > 0.05 {
      // Early, do nothing
      return
    }

    // Late frame handling
    // If late (negative waitTime), we might need to drop
    let frameDuration = 1.0 / frameRate

    // Loop to catch up if we are very late
    // We use a simplified loop to drop frames until we are within window or buffer empty
    while waitTime < -frameDuration {
      _ = await frameBuffer.pop()
      droppedFrameCount += 1

      // Peek next to see if we are still late
      guard let next = await frameBuffer.peek() else { return }

      // Update waitTime for the new 'next' frame
      if await audioPlayer.hasBufferedAudio && audioPlayer.isPlaying {
        // For audio sync, time moves forward, so waitTime might change
        let newTime = audioPlayer.getMediaTime()
        waitTime = next.presentationTime - newTime
      } else {
        let newTime = (CACurrentMediaTime() - playbackStartTime) + firstFramePTS
        waitTime = next.presentationTime - newTime
      }
    }

    // Display
    if let frame = await frameBuffer.pop() {
      renderer?.enqueue(frame)

      // Fire and forget frame update to MainActor
      if let frameHandler = frameUpdateHandler {
        Task { @MainActor in
          frameHandler(frame)
        }
      }

      // Update stats
      let pqCount = await packetQueue.count
      let fbCount = await frameBuffer.count
      let drift = await (audioPlayer.hasBufferedAudio && audioPlayer.isPlaying) ? waitTime : 0.0

      let stats = PlayerDebugStats(
        packetQueueCount: pqCount,
        packetQueueMax: await packetQueue.maxSize,
        frameBufferCount: fbCount,
        frameBufferMax: await frameBuffer.maxSize,
        avDrift: drift,
        droppedFrameCount: droppedFrameCount,
        isHardwareDecoded: isHardware,
        decoderName: decoderName,
        displayRefreshRate: await displayLink?.refreshRate ?? 60.0,
        keyframeCount: 0
      )

      if let handler = statsUpdateHandler {
        await MainActor.run {
          handler(stats)
        }
      }
    }
  }
}

// MARK: - DisplayLink Driver

@MainActor
private class DisplayLinkDriver: NSObject {
  private var displayLink: CADisplayLink?
  var onFrame: (() -> Void)?

  init(onFrame: @escaping () -> Void) {
    self.onFrame = onFrame
    super.init()
    if let screen = NSScreen.main {
      self.displayLink = screen.displayLink(target: self, selector: #selector(frameStep))
      self.displayLink?.add(to: .main, forMode: .common)
      self.displayLink?.isPaused = true  // Start paused
    }
  }

  @objc private func frameStep(_ link: CADisplayLink) {
    onFrame?()
  }

  func start() {
    displayLink?.isPaused = false
  }

  func stop() {
    displayLink?.isPaused = true
  }

  func invalidate() {
    displayLink?.invalidate()
  }

  var refreshRate: Double {
    guard let link = displayLink, link.duration > 0 else { return 60.0 }
    return 1.0 / link.duration
  }
}
