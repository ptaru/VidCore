//
//  PlaybackState.swift
//  VidCore
//
//  Represents the current state of video playback
//

import Foundation

/// Represents the current state of video playback
public enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case playing
    case paused
    case seeking
    case finished
    case error(VideoPlayerError)
}
