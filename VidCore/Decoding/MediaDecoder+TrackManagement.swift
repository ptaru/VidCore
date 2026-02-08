//
//  MediaDecoder+TrackManagement.swift
//  VidCore
//

import Foundation

extension MediaDecoder {
    /// Asynchronously returns all available audio tracks from the container.
    /// - Returns: Array of `AudioTrackInfo`, empty if no audio tracks.
    public func getAudioTracks() -> [AudioTrackInfo] {
        return videoInfo.audioTracks
    }

    /// Asynchronously retrieves the currently selected audio stream index.
    /// - Returns: Stream index, or -1 if no audio is selected or the decoder is closed.
    public func selectedAudioStreamIndex() async -> Int {
        if checkIsClosed() {
            return -1
        }

        return Int(await demuxerActor.selectedAudioStreamIndex())
    }

    /// Asynchronously switches to a different audio track by its stream index.
    ///
    /// This reinitializes the audio decoder for the new codec format.
    /// - Parameter streamIndex: The stream index to switch to.
    /// - Returns: `true` if successful, `false` on error or if the decoder is unavailable.
    public func switchAudioTrack(to streamIndex: Int) async -> Bool {
        guard let decoderActor = self.decoderActor, !checkIsClosed() else {
            return false
        }

        // Update demuxer to use the new audio stream
        guard await demuxerActor.selectAudioStream(Int32(streamIndex)) else {
            return false
        }

        // Build decoder config for the new audio stream
        guard
            let newDecoderConfig = await demuxerActor.getAudioDecoderConfig(
                forStream: Int32(streamIndex))
        else {
            return false
        }

        // Switch audio stream in decoder (handles codec reinitialization)
        return await decoderActor.switchAudioStream(newDecoderConfig)
    }

    // MARK: - Subtitle Track Management

    /// Returns all available subtitle tracks in the container.
    public func getSubtitleTracks() -> [SubtitleTrackInfo] {
        return videoInfo.subtitleTracks
    }

    /// Asynchronously returns the currently selected subtitle stream index.
    /// - Returns: The stream index, or -1 if none is selected or decoder is closed.
    public func selectedSubtitleStreamIndex() async -> Int {
        if checkIsClosed() {
            return -1
        }

        return Int(await demuxerActor.selectedSubtitleStreamIndex())
    }

    /// Asynchronously switches to a different subtitle track.
    /// - Parameter streamIndex: The stream index to switch to, or -1 to disable subtitles.
    /// - Returns: `true` if the switch was successful.
    public func switchSubtitleTrack(to streamIndex: Int) async -> Bool {
        guard let decoderActor = self.decoderActor, !checkIsClosed() else {
            return false
        }

        if streamIndex == -1 {
            // Disable subtitles
            _ = await demuxerActor.selectSubtitleStream(-1)
            self.assPipeline.reset(flush: true)

            performUnderLock {
                self._isASSActive = false
            }

            return true

        }

        self.assPipeline.reset(flush: true)

        // Select stream in demuxer
        guard await demuxerActor.selectSubtitleStream(Int32(streamIndex)) else {
            return false
        }

        // Get config
        guard
            let newConfig = await demuxerActor.getSubtitleDecoderConfig(
                forStream: Int32(streamIndex))
        else {
            return false
        }

        self.assPipeline.configureHeaderIfNeeded(from: newConfig)

        // Update local ASS state cache.
        performUnderLock {
            self._isASSActive = (self.assRenderer != nil)
        }

        return await decoderActor.switchSubtitleStream(newConfig)
    }
}
