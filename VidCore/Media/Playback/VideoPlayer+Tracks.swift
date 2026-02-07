//
//  VideoPlayer+Tracks.swift
//  VidCore
//

import Foundation

extension VideoPlayer {
  // MARK: - Audio Track Selection

  /// All available audio tracks in the current video.
  public var audioTracks: [AudioTrackInfo] {
    videoInfo?.audioTracks ?? []
  }

  /// Select an audio track by its index in the audioTracks array.
  ///
  /// This method performs an accurate seek to the current playback position after switching
  /// tracks to ensure the new audio stream is correctly synchronized.
  ///
  /// - Parameter index: Index of the audio track to select.
  public func selectAudioTrack(at index: Int) async {
    guard let decoder = decoder else { return }
    guard index >= 0 && index < audioTracks.count else { return }
    guard index != selectedAudioTrackIndex else { return }

    let track = audioTracks[index]
    let currentPosition = currentTime
    let wasPlaying = state == .playing

    // 1. Pause playback
    if wasPlaying {
      pause()
    }

    // 2. Switch demuxer and decoder to the new audio stream
    let success = await decoder.switchAudioTrack(to: track.streamIndex)
    guard success else {
      if wasPlaying {
        play()
      }
      return
    }

    // Update state
    selectedAudioTrackIndex = index
    videoInfo = decoder.videoInfo

    // 3. Accurate seek to reset state and maintain position
    await seek(to: currentPosition)

    // 4. Resume playback if we were playing
    if wasPlaying {
      play()
    }
  }

  // MARK: - Subtitle Track Selection

  /// All available subtitle tracks in the current video.
  public var subtitleTracks: [SubtitleTrackInfo] {
    videoInfo?.subtitleTracks ?? []
  }

  /// Select a subtitle track.
  /// - Parameter index: Index of the track in `subtitleTracks`. Use -1 to disable subtitles.
  public func selectSubtitleTrack(at index: Int) async {
    guard let decoder = decoder else { return }
    guard index >= -1 && index < subtitleTracks.count else { return }
    guard index != selectedSubtitleTrackIndex else { return }

    // If disabling (-1), just clear state
    if index == -1 {
      _ = await decoder.switchSubtitleTrack(to: -1)
      selectedSubtitleTrackIndex = -1
      currentSubtitle = nil
      subtitles.removeAll()
      return
    }

    let track = subtitleTracks[index]

    // Switch track in decoder
    // Note: We don't necessarily need to seek if we just want to start showing from now,
    // but seeking ensures we get the current subtitle if we are in the middle of one.
    // For now, let's just switch lightly without full seek-reset cycle unless needed.

    let success = await decoder.switchSubtitleTrack(to: track.streamIndex)
    if success {
      selectedSubtitleTrackIndex = index
      // Clear old subtitles
      subtitles.removeAll()
      currentSubtitle = nil
    }
  }
}
