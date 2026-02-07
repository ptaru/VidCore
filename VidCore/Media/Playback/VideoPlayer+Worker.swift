//
//  VideoPlayer+Worker.swift
//  VidCore
//

import Foundation

// MARK: - Playback Worker Delegate

extension VideoPlayer: PlaybackWorkerDelegate {
  func workerDidRenderVideoFrame(_ frame: VideoFrame) {
    currentFrame = frame
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
  }

  func workerDidFinishStream() {
    guard state == .playing else { return }
    state = .finished
    Task { await playbackClock.pause() }
    Task { await audioOutput.flush() }
  }

  func workerRefreshDebugStats(videoPTS: Double?) async {
    await refreshDebugStats(videoPTS: videoPTS)
  }
}
