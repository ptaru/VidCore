//
//  VideoDecoder+Subtitles.swift
//  VidCore
//

import CoreGraphics
import Foundation

extension VideoDecoder {
  /// Whether the currently selected subtitle track is ASS/SSA.
  public var isCurrentSubtitleTrackASS: Bool {
    return assPipeline.isASSActive(for: demuxer)
  }

  /// Renders the subtitle image for a specific time and size.
  /// - Parameters:
  ///   - time: The presentation time in seconds.
  ///   - size: The target render size in points.
  ///   - scale: The display scale.
  /// - Returns: A tuple containing the rendered image and a change counter.
  public func getSubtitleImage(
    at time: Double,
    size: CGSize,
    scale: CGFloat = 2.0
  ) -> (image: CGImage?, changed: Int) {
    // Only render if we have an active ASS renderer and the current track requires it.
    if isCurrentSubtitleTrackASS, let renderer = assRenderer {
      let image = renderer.render(atTimestamp: time, size: size, scale: scale)
      return (image, Int(renderer.lastRenderChanged))
    }
    return (nil, 0)
  }

  /// Resets the subtitle rendering state.
  public func resetSubtitleState() async {
    await withCheckedContinuation { continuation in
      decodeQueue.async { [weak self] in
        guard let self = self else {
          continuation.resume()
          return
        }

        self.lock.lock()
        defer { self.lock.unlock() }

        guard !self.isClosed else {
          continuation.resume()
          return
        }

        self.assPipeline.reset(flush: true)

        if let demuxer = self.demuxer {
          let index = demuxer.selectedSubtitleStreamIndex()
          if index >= 0,
             let config = demuxer.getSubtitleDecoderConfig(forStream: index) {
            self.assPipeline.configureHeaderIfNeeded(from: config)
          }
        }

        continuation.resume()
      }
    }
  }

  /// Cleans ASS/SSA formatted subtitle text.
  func cleanSubtitleText(_ text: String) -> String {
    var cleaned = text

    // 1. Remove ASS event prefix (comma-separated fields)
    // Heuristic: If we find 8 or more commas at the start, drop them.
    // Standard format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    // User reported 8 commas: 14,0,Default,,0,0,0,,Text
    // We'll look for the first 8 or 9 fields.
    // Pattern: at least 8 groups of "something," at the start.
    // Use simple comma counting to be robust.

    let parts = cleaned.split(separator: ",", maxSplits: 10, omittingEmptySubsequences: false)
    if parts.count >= 9 {  // 8 commas implies 9 parts
      // Check if the first few parts look like metadata (digits, known styles)
      // Or just blindly take the 9th part (index 8) onwards.
      // Given "14,0,Default,,0,0,0,,Text", the text is parts[8...] joined back.
      // Or simply find the 8th comma index.

      // Let's count commas to find the cut point.
      var commaCount = 0
      var cutIndex: String.Index?

      for (index, char) in cleaned.enumerated() {
        if char == "," {
          commaCount += 1
          if commaCount == 8 {
            // Found the 8th comma. The text likely starts after this.
            let nextIndex = cleaned.index(cleaned.startIndex, offsetBy: index + 1)
            if nextIndex < cleaned.endIndex {
              cutIndex = nextIndex
            }
            // Keep checking if 9th comma exists? (Standard is 9)
            // But user log shows 8 commas. The last field (Text) contains the content.
            // If we cut after 8th comma: "I will make it happen."
            // If we wait for 9th, we might cut into text if user source is non-standard.
            // A safe heuristic involves checking what these fields are, but stripped is better.
            // Let's settle on stripping first 8 fields (8 commas).
            // But wait, if text has commas, simple split won't work perfectly if we don't limit splits?
            break
          }
        }
      }

      if let cutIndex = cutIndex {
        cleaned = String(cleaned[cutIndex...])
      }
    }

    // 2. Replace \N with newline
    cleaned = cleaned.replacingOccurrences(of: "\\N", with: "\n")
    cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")

    return cleaned
  }
}
