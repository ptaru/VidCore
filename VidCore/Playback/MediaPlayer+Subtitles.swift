//
//  MediaPlayer+Subtitles.swift
//  VidCore
//

import CoreGraphics
import Foundation

extension MediaPlayer {
    func updateSubtitles(for time: Double) {
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
            updateDisplayLinkFrameRate(
                isAnimating: isASSAnimating(at: time),
                isASSActive: isASSActive()
            )
            scheduleASSRender(for: time, decoder: decoder)
            return  // Early exit, async update will handle it
        }

        // If ASS is active, never show plain-text ASS frames (prevents flashes).
        if decoder?.isCurrentSubtitleTrackASS == true,
            let subtitle = newSubtitle,
            subtitle.isASS,
            case .text = subtitle.content
        {
            newSubtitle = nil
        }

        // Only update if changed to avoid excessive SwiftUI view updates and flickering
        if newSubtitle != currentSubtitle {
            currentSubtitle = newSubtitle
        }
    }

    private func subtitleRenderInterval(isAnimating: Bool, isASSActive: Bool) -> Double {
        if isAnimating || isASSActive {
            return 1.0 / 60.0
        }
        let fps = max(videoInfo?.frameRate ?? 30.0, 1.0)
        let clamped = min(max(fps, 24.0), 60.0)
        return 1.0 / clamped
    }

    private func isASSActive() -> Bool {
        decoder?.isCurrentSubtitleTrackASS == true
    }

    private func isASSAnimating(at time: Double) -> Bool {
        time <= assAnimatingUntilTime
    }

    private func shouldStartASSRender(for time: Double) -> Bool {
        if state != .playing {
            return true
        }
        let delta = abs(time - lastASSRenderTime)
        if delta
            >= subtitleRenderInterval(
                isAnimating: isASSAnimating(at: time),
                isASSActive: isASSActive()
            )
        {
            return true
        }
        return delta >= 0.5
    }

    func scheduleASSRender(for time: Double, decoder: MediaDecoder) {
        pendingASSRenderTime = time

        guard subtitleRenderTask == nil else { return }
        guard shouldStartASSRender(for: time) else { return }

        subtitleRenderTask = Task.detached(priority: .userInitiated) { [weak self, decoder] in
            await self?.runASSRenderLoop(decoder: decoder)
        }
    }

    private func runASSRenderLoop(decoder: MediaDecoder) async {
        while true {
            if Task.isCancelled {
                break
            }

            let renderTime: Double? = await MainActor.run {
                if let time = pendingASSRenderTime {
                    pendingASSRenderTime = nil
                    return time
                }
                return nil
            }

            guard let time = renderTime else { break }
            if Task.isCancelled {
                break
            }

            let (size, scale, info, playbackTime, interval, animating, assActive):
                (CGSize, CGFloat, VideoInfo?, Double, Double, Bool, Bool) =
                    await MainActor.run {
                        let animating = isASSAnimating(at: self.currentTime)
                        let assActive = isASSActive()
                        return (
                            viewSize,
                            contentScale,
                            videoInfo,
                            self.currentTime,
                            subtitleRenderInterval(isAnimating: animating, isASSActive: assActive),
                            animating,
                            assActive
                        )
                    }

            var renderSize = size
            if renderSize.width <= 0 || renderSize.height <= 0, let info {
                renderSize = CGSize(width: info.width, height: info.height)
            }
            if renderSize.width <= 0 || renderSize.height <= 0 {
                continue
            }

            if let info = info {
                let storageSize = CGSize(width: Double(info.width), height: Double(info.height))
                decoder.assRenderer?.setStorageSize(storageSize, aspect: info.displayAspectRatio)
            }

            let (image, changed) = decoder.getSubtitleImage(
                at: time, size: renderSize, scale: scale)

            let maxSkew = max(0.25, interval * 2.0)
            if abs(playbackTime - time) > maxSkew {
                continue
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastASSRenderTime = time
                if changed == 1 {
                    self.assAnimatingUntilTime = max(self.assAnimatingUntilTime, time + 0.5)
                } else if !animating {
                    self.assAnimatingUntilTime = max(self.assAnimatingUntilTime, time)
                }
                self.updateDisplayLinkFrameRate(
                    isAnimating: self.isASSAnimating(at: playbackTime),
                    isASSActive: assActive
                )

                if let image {
                    let newSubtitle = SubtitleFrame(
                        content: .image(ImageBox(image)),
                        isASS: true,
                        startTime: time,
                        endTime: nil  // ASS manages its own duration via the renderer
                    )

                    if self.currentSubtitle != newSubtitle {
                        self.currentSubtitle = newSubtitle
                    }
                } else if self.currentSubtitle?.isASS == true {
                    self.currentSubtitle = nil
                }
            }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.subtitleRenderTask = nil
            if let pendingTime = self.pendingASSRenderTime,
                let decoder = self.decoder,
                self.shouldStartASSRender(for: pendingTime)
            {
                self.subtitleRenderTask = Task.detached(priority: .userInitiated) {
                    [weak self, decoder] in
                    await self?.runASSRenderLoop(decoder: decoder)
                }
            }
        }
    }

    func updateDisplayLinkFrameRate(isAnimating: Bool, isASSActive: Bool) {
        if isAnimating {
            displayLink.setPreferredFrameRate(nil)
            return
        }
        if isASSActive {
            displayLink.setPreferredFrameRate(60)
            return
        }
        let fps = videoInfo?.frameRate ?? 0
        displayLink.setPreferredFrameRate(fps > 0 ? fps : nil)
    }
}
