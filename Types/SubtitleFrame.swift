//
//  SubtitleFrame.swift
//  VidCore
//
//  A decoded subtitle frame.
//

import CoreGraphics
import Foundation

/// Represents a decoded subtitle content.
public enum SubtitleContent: Sendable, Equatable {
  /// Plain text or marked up text (e.g. ASS/SSA, SRT).
  case text(String)
  /// Bitmap images for image-based subtitles (e.g. PGS, VobSub).
  case bitmaps([SubtitleBitmap])
}

/// A single bitmap element in a subtitle frame.
public struct SubtitleBitmap: Sendable, Equatable {
  /// Raw RGBA pixel data.
  public let data: Data
  /// Raw (pixel) width of the bitmap.
  public let width: Int
  /// Raw (pixel) height of the bitmap.
  public let height: Int
  /// Normalized frame (x, y, width, height) relative to video size (0.0-1.0).
  public let rect: CGRect

  public init(data: Data, width: Int, height: Int, rect: CGRect) {
    self.data = data
    self.width = width
    self.height = height
    self.rect = rect
  }
}

/// A decoded subtitle frame with timing and content.
public struct SubtitleFrame: Sendable, Equatable {
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
