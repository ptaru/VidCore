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
    /// Single full-frame image (e.g. rendered ASS).
    case image(ImageBox)
}

/// A wrapper for CGImage to support Equatable and Sendable.
public struct ImageBox: @unchecked Sendable, Equatable {
    public let image: CGImage

    /// Creates a new image box.
    /// - Parameter image: The underlying CGImage.
    public init(_ image: CGImage) {
        self.image = image
    }

    public static func == (lhs: ImageBox, rhs: ImageBox) -> Bool {
        return lhs.image === rhs.image
    }
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

    /// Creates a new subtitle bitmap.
    /// - Parameters:
    ///   - data: The raw pixel data.
    ///   - width: The bitmap width in pixels.
    ///   - height: The bitmap height in pixels.
    ///   - rect: The normalized display rectangle.
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
    /// Whether the text content is ASS/SSA formatted (if applicable).
    public let isASS: Bool
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

    /// Creates a new subtitle frame.
    /// - Parameters:
    ///   - content: The subtitle content.
    ///   - isASS: Whether the content is ASS/SSA.
    ///   - startTime: The start time in seconds.
    ///   - endTime: The end time in seconds.
    public init(
        content: SubtitleContent, isASS: Bool = false, startTime: Double, endTime: Double? = nil
    ) {
        self.content = content
        self.isASS = isASS
        self.startTime = startTime
        self.endTime = endTime
    }
}
