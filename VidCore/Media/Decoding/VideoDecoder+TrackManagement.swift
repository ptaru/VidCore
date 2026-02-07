//
//  VideoDecoder+TrackManagement.swift
//  VidCore
//

import Foundation

extension VideoDecoder {
  /// Get all available audio tracks from the container.
  /// - Returns: Array of audio track info, empty if no audio tracks.
  public func getAudioTracks() -> [AudioTrackInfo] {
    lock.lock()
    defer { lock.unlock() }
    return videoInfo.audioTracks
  }

  /// Get the currently selected audio stream index.
  /// - Returns: Stream index, or -1 if no audio.
  public func selectedAudioStreamIndex() -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, let demuxer = self.demuxer else { return -1 }
    return Int(demuxer.selectedAudioStreamIndex())
  }

  /// Switch to a different audio track by its stream index.
  /// This reinitializes the audio decoder for the new codec format.
  /// - Parameter streamIndex: The stream index to switch to.
  /// - Returns: true if successful, false on error.
  public func switchAudioTrack(to streamIndex: Int) async -> Bool {
    await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: false)
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed, let demuxer = self.demuxer, let decoder = self.decoder else {
          continuation.resume(returning: false)
          return
        }

        // Update demuxer to use the new audio stream
        guard demuxer.selectAudioStream(Int32(streamIndex)) else {
          continuation.resume(returning: false)
          return
        }

        // Build decoder config for the new audio stream
        guard let newDecoderConfig = self.buildAudioDecoderConfig(streamIndex: streamIndex) else {
          continuation.resume(returning: false)
          return
        }

        // Switch audio stream in decoder (handles codec reinitialization)
        let success = decoder.switchAudioStream(newDecoderConfig)
        continuation.resume(returning: success)
      }
    }
  }

  /// Build decoder configuration for a specific audio stream.
  private func buildAudioDecoderConfig(streamIndex: Int) -> [String: Any]? {
    guard let demuxer = self.demuxer else { return nil }
    return demuxer.getAudioDecoderConfig(forStream: Int32(streamIndex))
  }

  // MARK: - Subtitle Track Management

  /// Get all available subtitle tracks from the container.
  public func getSubtitleTracks() -> [SubtitleTrackInfo] {
    lock.lock()
    defer { lock.unlock() }
    return videoInfo.subtitleTracks
  }

  /// Get the currently selected subtitle stream index.
  public func selectedSubtitleStreamIndex() -> Int {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed, let demuxer = self.demuxer else { return -1 }
    return Int(demuxer.selectedSubtitleStreamIndex())
  }

  /// Switch to a different subtitle track by its stream index.
  public func switchSubtitleTrack(to streamIndex: Int) async -> Bool {
    await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume(returning: false)
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed, let demuxer = self.demuxer, let decoder = self.decoder else {
          continuation.resume(returning: false)
          return
        }

        if streamIndex == -1 {
          // Disable subtitles
          _ = demuxer.selectSubtitleStream(-1)
          self.assPipeline.reset(flush: true)
          continuation.resume(returning: true)
          return
        }

        self.assPipeline.reset(flush: true)

        guard demuxer.selectSubtitleStream(Int32(streamIndex)) else {
          continuation.resume(returning: false)
          return
        }

        guard let newConfig = self.buildSubtitleDecoderConfig(streamIndex: streamIndex) else {
          continuation.resume(returning: false)
          return
        }

        self.assPipeline.configureHeaderIfNeeded(from: newConfig)

        let success = decoder.switchSubtitleStream(newConfig)
        continuation.resume(returning: success)
      }
    }
  }

  private func buildSubtitleDecoderConfig(streamIndex: Int) -> [String: Any]? {
    guard let demuxer = self.demuxer else { return nil }
    return demuxer.getSubtitleDecoderConfig(forStream: Int32(streamIndex))
  }
}
