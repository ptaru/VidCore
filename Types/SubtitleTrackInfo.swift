//
//  SubtitleTrackInfo.swift
//  VidCore
//
//  Metadata about a subtitle track.
//

import Foundation

/// Metadata about a subtitle track.
///
/// Contains information about a subtitle stream's codec, language, and title.
/// Used for subtitle track selection in multi-track files.
public struct SubtitleTrackInfo: Sendable, Equatable, Identifiable {
  /// Unique identifier (stream index).
  public let id: Int
  /// Stream index in the container.
  public let streamIndex: Int
  /// Language code (e.g., "eng", "jpn", "spa"), nil if not specified.
  public let language: String?
  /// Track title (e.g., "Full Subtitles"), nil if not specified.
  public let title: String?
  /// Subtitle codec name (e.g., "subrip", "ass", "mov_text", "pgs").
  public let codecName: String
  /// Whether this is the default subtitle track.
  public let isDefault: Bool
  /// Whether this is a known bitmap format (e.g. dvd_subtitle, pgs, hdmv_pgs).
  public let isBitmap: Bool

  /// Display name for the track (full format).
  /// Format: "Title - Language (Codec)" or "Language (Codec)"
  public var displayName: String {
    let codecUpper = codecName.uppercased()
    let lang = language?.uppercased() ?? "Unknown"
    let typeInfo = isBitmap ? "Bitmap" : "Text"

    if let title = title, !title.isEmpty {
      return "\(title) - \(lang)"
    } else {
      return "\(lang) (\(codecUpper))"
    }
  }

  /// Short display name for compact UI.
  public var shortDisplayName: String {
    let lang = language?.uppercased() ?? "Unknown"
    return lang
  }

  public init(
    streamIndex: Int, language: String?, title: String?, codecName: String, isDefault: Bool = false,
    isBitmap: Bool = false
  ) {
    self.id = streamIndex
    self.streamIndex = streamIndex
    self.language = language
    self.title = title
    self.codecName = codecName
    self.isDefault = isDefault
    self.isBitmap = isBitmap
  }
}
