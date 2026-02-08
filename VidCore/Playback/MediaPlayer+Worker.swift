//
//  MediaPlayer+Worker.swift
//  VidCore
//

import Foundation

// MARK: - Playback Worker Delegate

extension MediaPlayer: PlaybackWorkerDelegate {
  func workerDidRenderVideoFrame(_ frame: VideoFrame) {
    if pendingPlay {
      pendingPlay = false
      Task {
        await playbackClock.play(rate: playbackRate)
      }
    }
    currentFrame = frame
    // Ensure we are playing if we were stalled
    if state == .playing && playbackClock.rate == 0 {
      Task { await playbackClock.setRate(playbackRate) }
    }
  }

  func workerDidDecodeSubtitle(_ subtitle: SubtitleFrame) {
    subtitles.append(subtitle)
    // Keep only recent subtitles (e.g. last 100)
    if subtitles.count > 100 {
      subtitles.removeFirst()
    }
  }

  func workerDidDetectAudio() {
    hasAudio = true
    // If audio-only or audio starts first
    if pendingPlay {
      pendingPlay = false
      Task {
        await playbackClock.play(rate: playbackRate)
      }
    }
  }

  func workerDidFinishStream() {
    guard state == .playing else { return }
    state = .finished
    Task { await playbackClock.pause() }
    Task { await audioOutput.flush() }
  }

  func workerDidStall() {
    guard state == .playing else { return }
    Task { await playbackClock.setRate(0.0) }
  }

  func workerDidUnstall() {
    guard state == .playing else { return }
    Task { await playbackClock.setRate(playbackRate) }
  }

  func workerRefreshDebugStats(videoPTS: Double?) async {
    await refreshDebugStats(videoPTS: videoPTS)
  }
}
