//
//  MediaPlayer+Seeking.swift
//  VidCore
//

import Foundation

extension MediaPlayer {
    private var scrubMinInterval: TimeInterval? {
        guard let fps = scrubRateLimitFPS, fps > 0 else { return nil }
        return 1.0 / fps
    }

    private func scrubNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func resetScrubLimiterState() {
        scrubDispatchTask?.cancel()
        scrubDispatchTask = nil
        pendingScrubTime = nil
        lastScrubDispatchTime = nil
    }

    private func launchScrubSeek(to time: Double) {
        let previousTask = currentSeekTask
        currentSeekTask = Task { [weak self] in
            previousTask?.cancel()
            await self?.decoder?.requestDemuxAbort()
            _ = await previousTask?.result
            await self?.decoder?.clearDemuxAbort()

            if Task.isCancelled { return }

            await self?.performScrubOperation(to: time)
        }
    }

    private func scheduleScrubDispatch(after delay: TimeInterval) {
        guard isScrubbing, scrubDispatchTask == nil else { return }

        let sleepNanos = UInt64(max(0, delay) * 1_000_000_000)
        scrubDispatchTask = Task { [weak self] in
            if sleepNanos > 0 {
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
            await self?.dispatchPendingScrubIfNeeded()
        }
    }

    private func dispatchPendingScrubIfNeeded() async {
        scrubDispatchTask = nil
        guard isScrubbing else { return }
        guard let pending = pendingScrubTime else { return }

        if let minInterval = scrubMinInterval, let lastDispatch = lastScrubDispatchTime {
            let elapsed = scrubNow() - lastDispatch
            if elapsed < minInterval {
                scheduleScrubDispatch(after: minInterval - elapsed)
                return
            }
        }

        pendingScrubTime = nil
        lastScrubDispatchTime = scrubNow()
        launchScrubSeek(to: pending)
    }

    // MARK: - Public Scrubbing API

    /// Begin a scrubbing session.
    ///
    /// This pauses playback, stops the decode loop, and prepares the player for rapid
    /// coalesced seeking. Use `scrub(to:)` to update the position.
    public func beginScrub() async {
        // Cancel active seek/scrub
        currentSeekTask?.cancel()
        await decoder?.requestDemuxAbort()
        _ = await currentSeekTask?.result
        await decoder?.clearDemuxAbort()
        currentSeekTask = nil

        resetScrubLimiterState()

        // Pause system
        await playbackClock.pause()
        audioOutput.setPlaybackState(isPlaying: false, rate: playbackRate)

        // Store state to resume later if not already scrubbing
        if state != .scrubbing {
            wasPlayingBeforeScrub = (state == .playing)
        }

        // Stop background workers
        await stopTasks()
        await packetQueue.suspend()

        // Update state last to prevent race conditions
        isScrubbing = true
        state = .scrubbing
    }

    /// Update the scrub position.
    ///
    /// This method is designed to be called frequently (e.g., from a slider drag).
    /// Updates are coalesced by cancelling the previous pending task.
    ///
    /// - Parameter time: The target time to scrub to.
    public func scrub(to time: Double) async {
        guard isScrubbing else { return }

        guard let minInterval = scrubMinInterval else {
            launchScrubSeek(to: time)
            return
        }

        pendingScrubTime = time

        if let lastDispatch = lastScrubDispatchTime {
            let elapsed = scrubNow() - lastDispatch
            if elapsed >= minInterval {
                scrubDispatchTask?.cancel()
                scrubDispatchTask = nil
                if let pending = pendingScrubTime {
                    pendingScrubTime = nil
                    lastScrubDispatchTime = scrubNow()
                    launchScrubSeek(to: pending)
                }
            } else {
                scheduleScrubDispatch(after: minInterval - elapsed)
            }
        } else {
            scrubDispatchTask?.cancel()
            scrubDispatchTask = nil
            if let pending = pendingScrubTime {
                pendingScrubTime = nil
                lastScrubDispatchTime = scrubNow()
                launchScrubSeek(to: pending)
            }
        }
    }

    /// End the scrubbing session.
    public func endScrub() async {
        guard isScrubbing else { return }

        scrubDispatchTask?.cancel()
        scrubDispatchTask = nil
        if let pending = pendingScrubTime {
            pendingScrubTime = nil
            launchScrubSeek(to: pending)
        }
        isScrubbing = false

        // Wait for final scrub to complete
        _ = await currentSeekTask?.result
        currentSeekTask = nil
        lastScrubDispatchTime = nil

        // Perform cleanup
        await packetQueue.reset()
        await audioOutput.flush()
        await decoder?.resetSubtitleState()

        let hasErrorState: Bool = {
            if case .error = state { return true }
            return false
        }()
        if !hasErrorState {
            state = .paused  // Now safe to transition
        }

        // Resume playback if needed
        if wasPlayingBeforeScrub && !hasErrorState {
            play()
        }
    }

    // MARK: - Internal Workers

    /// Scrub seek operation (includes heavy logic but is cancellable)
    private func performScrubOperation(to time: Double) async {
        guard let decoder = decoder else { return }

        do {
            let duration = await snapshotDuration()
            let clamped = max(0, min(time, duration))

            try Task.checkCancellation()

            // Seek Decoder
            if let frame = try await decoder.seek(to: clamped)
            {
                try Task.checkCancellation()

                if frame.pixelBuffer == nil {
                    let prerollFrames = await decoder.consumePendingPassthroughFrames()
                    try Task.checkCancellation()

                    if let sbRenderer = renderer as? SampleBufferRenderer {
                        sbRenderer.flush()
                    }

                    for prerollFrame in prerollFrames {
                        try Task.checkCancellation()
                        if let readinessAwaiter = renderer as? MediaDataReadinessAwaiting {
                            await readinessAwaiter.waitUntilReady()
                        }
                        await renderer?.enqueue(prerollFrame)
                    }

                    await renderFrame(frame, flushRenderer: false)
                } else {
                    // Render immediately
                    await renderFrame(frame, flushRenderer: true)
                }

                // Sync clock to frame time
                await playbackClock.seek(to: frame.presentationTime)
            } else {
                // Seek failed/EOF, set clock
                currentTime = clamped
                await playbackClock.seek(to: clamped)
            }

            // Reset subtitles
            subtitles.removeAll()
            currentSubtitle = nil
            await decoder.resetSubtitleState()

        } catch is CancellationError {
            // Task cancelled, ignore
        } catch {
            subtitles.removeAll()
            currentSubtitle = nil
            state = .error(.seekFailed)
        }
    }

}
