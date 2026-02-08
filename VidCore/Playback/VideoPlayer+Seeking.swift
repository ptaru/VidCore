//
//  VideoPlayer+Seeking.swift
//  VidCore
//

import Foundation

extension VideoPlayer {
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

  func prepareForScrub() async -> PlaybackState {
    let previousState = state
    state = .scrubbing
    lastScrubFrameTime = nil

    await stopTasks()
    await playbackClock.pause()
    audioOutput.setPlaybackState(isPlaying: false, rate: playbackRate)
    await packetQueue.suspend()

    return previousState
  }

  func performScrubSeek(to seconds: Double, scrubToken: UInt64) async {
    guard let decoder = decoder else { return }
    guard !Task.isCancelled else { return }
    guard scrubToken == currentScrubToken else { return }
    let clampedSeconds = max(0, min(seconds, duration))

    do {
      guard scrubToken == currentScrubToken else { return }
      if let frame = try await decoder.seek(to: clampedSeconds) {
        guard !Task.isCancelled else { return }
        guard scrubToken == currentScrubToken else { return }
        lastScrubFrameTime = frame.presentationTime
        await renderFrame(frame, flushRenderer: true)
      } else {
        guard !Task.isCancelled else { return }
        guard scrubToken == currentScrubToken else { return }
        currentTime = clampedSeconds
        updateSubtitles(for: clampedSeconds)
      }
    } catch {
    }
  }

  func updateScrubToken(_ token: UInt64) {
    currentScrubToken = token
  }

  func requestScrubAbort() async {
    await decoder?.requestDemuxAbort()
  }

  func clearScrubAbort() async {
    await decoder?.clearDemuxAbort()
  }

  func performSeek(to seconds: Double, resumePlayback: Bool?) async {
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
    
    guard !Task.isCancelled else { return }
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

  func finishScrub(at targetTime: Double, resumePlayback: Bool) async {
    state = .seeking
    // Always commit the final seek to the user's target time, even if the preview frame lagged behind.
    let resumeTime = targetTime
    await playbackClock.seek(to: resumeTime)
    await audioOutput.flush()

    await packetQueue.reset()
    if let decoder {
      await decoder.resetSubtitleState()
    }
    subtitles.removeAll()
    currentSubtitle = nil
    lastSubtitleUpdateTime = 0
    lastASSRenderTime = 0
    pendingASSRenderTime = nil
    assAnimatingUntilTime = 0
    assAnimatingUntilTime = 0

    if let decoder {
      do {
        if let frame = try await decoder.seek(to: targetTime) {
          await renderFrame(frame, flushRenderer: true)
          await playbackClock.seek(to: frame.presentationTime)
        }
      } catch {
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

  func resetPlaybackStateForSeek() async {
    await packetQueue.reset()
    if let decoder {
      await decoder.resetSubtitleState()
    }
    subtitles.removeAll()
    currentSubtitle = nil
    lastSubtitleUpdateTime = 0
    lastASSRenderTime = 0
    pendingASSRenderTime = nil

    if let sbRenderer = renderer as? SampleBufferRenderer {
      sbRenderer.flush()
    }
  }
}

// MARK: - Seek/Scrub Coordinator

actor SeekCoordinator {
  private weak var player: VideoPlayer?
  private var activeSeekTask: Task<Void, Never>?
  private var latestScrubTime: Double?
  private var isScrubbing = false
  private var previewTask: Task<Void, Never>?
  private var scrubToken: UInt64 = 0

  init(player: VideoPlayer) {
    self.player = player
  }

  func cancelAll() async {
    if let player {
      await player.requestScrubAbort()
    }
    previewTask?.cancel()
    _ = await previewTask?.result
    previewTask = nil

    activeSeekTask?.cancel()
    _ = await activeSeekTask?.result
    activeSeekTask = nil

    latestScrubTime = nil
    isScrubbing = false
    scrubToken &+= 1
    if let player {
      let token = scrubToken
      await player.updateScrubToken(token)
      await player.clearScrubAbort()
    }
  }

  func seek(to seconds: Double) async {
    await cancelScrubIfNeeded()
    await cancelActiveSeek()

    guard let player = player else { return }

    // Explicitly abort any running demux/decode operations from the previous seek
    // to ensure the new seek starts immediately.
    await player.requestScrubAbort()

    // Clear the abort flag before starting the NEW seek
    await player.clearScrubAbort()

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
    scrubToken &+= 1
    let token = scrubToken
    await player.updateScrubToken(token)
    await player.clearScrubAbort()
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
    await player.requestScrubAbort()
    scrubToken &+= 1
    previewTask?.cancel()
    let token = scrubToken
    await player.updateScrubToken(token)
    await player.clearScrubAbort()
    previewTask = Task { [weak player] in
      await player?.performScrubSeek(to: clamped, scrubToken: token)
    }
  }

  func endScrub(resumePlayback: Bool) async {
    guard isScrubbing else { return }
    isScrubbing = false

    if let player {
      await player.requestScrubAbort()
    }
    previewTask?.cancel()
    _ = await previewTask?.result
    previewTask = nil
    scrubToken &+= 1
    if let player {
      let token = scrubToken
      await player.updateScrubToken(token)
      await player.clearScrubAbort()
    }

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
    latestScrubTime = nil
    isScrubbing = false
    if let player {
      await player.requestScrubAbort()
    }
    previewTask?.cancel()
    _ = await previewTask?.result
    previewTask = nil
    scrubToken &+= 1
    if let player {
      let token = scrubToken
      await player.updateScrubToken(token)
      await player.clearScrubAbort()
    }
  }

  private func cancelActiveSeek() async {
    activeSeekTask?.cancel()
    _ = await activeSeekTask?.result
    activeSeekTask = nil
  }
}
