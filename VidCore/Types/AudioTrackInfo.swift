//
//  AudioTrackInfo.swift
//  VidCore
//
//  Metadata about an audio track.
//

import Foundation

/// Metadata about an audio track.
///
/// Contains information about an audio stream's codec, language, and channel configuration.
/// Used for audio track selection in multi-track files.
public struct AudioTrackInfo: Sendable, Equatable, Identifiable {
    /// Unique identifier (stream index).
    public let id: Int
    /// Stream index in the container.
    public let streamIndex: Int
    /// Language code (e.g., "eng", "jpn", "spa"), nil if not specified.
    public let language: String?
    /// Track title (e.g., "Director's Commentary"), nil if not specified.
    public let title: String?
    /// Audio codec name (e.g., "aac", "ac3", "eac3", "opus").
    public let codecName: String
    /// Sample rate in Hz (e.g., 48000).
    public let sampleRate: Int
    /// Number of channels (e.g., 2 for stereo, 6 for 5.1).
    public let channels: Int
    /// Whether this is the default audio track from container metadata.
    public let isDefault: Bool

    /// Display name for the track (full format).
    /// Format: "Title - Language, Codec, Xch" or "Language, Codec, Xch" if no title.
    public var displayName: String {
        let codecUpper = codecName.uppercased()
        let channelsDesc = channels == 1 ? "1ch" : "\(channels)ch"
        let lang = language?.uppercased() ?? "Unknown"

        if let title = title, !title.isEmpty {
            return "\(title) - \(lang), \(codecUpper), \(channelsDesc)"
        } else {
            return "\(lang), \(codecUpper), \(channelsDesc)"
        }
    }

    /// Short display name for compact UI (e.g., picker button).
    /// Format: "Language • Codec" or just "Codec" if no language.
    public var shortDisplayName: String {
        let codecUpper = codecName.uppercased()
        if let lang = language, !lang.isEmpty {
            return "\(lang.uppercased()) • \(codecUpper)"
        } else {
            return codecUpper
        }
    }

    /// Creates a new audio track info.
    /// - Parameters:
    ///   - streamIndex: The stream index in the container.
    ///   - language: The language code.
    ///   - title: The track title.
    ///   - codecName: The codec name.
    ///   - sampleRate: The sample rate in Hz.
    ///   - channels: The number of channels.
    ///   - isDefault: Whether this is the default track.
    public init(
        streamIndex: Int, language: String?, title: String?, codecName: String, sampleRate: Int,
        channels: Int, isDefault: Bool = false
    ) {
        self.id = streamIndex
        self.streamIndex = streamIndex
        self.language = language
        self.title = title
        self.codecName = codecName
        self.sampleRate = sampleRate
        self.channels = channels
        self.isDefault = isDefault
    }
}
