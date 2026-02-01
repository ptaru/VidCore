//
//  SubtitleFrame.swift
//  VidCore
//
//  A decoded subtitle frame.
//

import CoreGraphics
import Foundation

/// Represents a decoded subtitle content.
public enum SubtitleContent: Sendable {
  /// Plain text or marked up text (e.g. ASS/SSA, SRT).
  case text(String)
  /// Bitmap image for image-based subtitles (e.g. PGS, VobSub).
  /// - data: Raw RGBA pixel data.
  /// - width: Raw (pixel) width of the bitmap.
  /// - height: Raw (pixel) height of the bitmap.
  /// - rect: Normalized frame (x, y, width, height) relative to video size (0.0-1.0).
  case bitmap(data: Data, width: Int, height: Int, rect: CGRect)
}

/// A decoded subtitle frame with timing and content.
public struct SubtitleFrame: Sendable {
  /// The actual content of the subtitle.
  public let content: SubtitleContent
  /// Start time of the subtitle in seconds.
  public let startTime: Double
  /// End time of the subtitle in seconds, or nil if unknown (e.g. valid until next event).
  public let endTime: Double?
  /// Duration in seconds, if known.
  public var duration: Double? {
    if let end = endTime {
      return end - startTime
    }
    return nil
  }

  public init(content: SubtitleContent, startTime: Double, endTime: Double? = nil) {
    self.content = content
    self.startTime = startTime
    self.endTime = endTime
  }
}
