//
//  MediaDecoder+Subtitles.swift
//  VidCore
//

import CoreGraphics
import Foundation

extension MediaDecoder {
    /// Whether the currently selected subtitle track is ASS/SSA.
    public var isCurrentSubtitleTrackASS: Bool {
        return self.isASSActive  // Uses the thread-safe property on MediaDecoder
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
        if checkIsClosed() {
            return
        }

        // Reset pipeline synchronously (class logic)
        self.assPipeline.reset(flush: true)

        // Re-configure based on selected stream from demuxer actor
        let index = await demuxerActor.selectedSubtitleStreamIndex()
        if index >= 0 {
            if let config = await demuxerActor.getSubtitleDecoderConfig(forStream: index) {
                self.assPipeline.configureHeaderIfNeeded(from: config)
            }
        }

        // Update active cache
        performUnderLock {
            self._isASSActive = (self.assRenderer != nil)
        }
    }

    /// Cleans ASS/SSA formatted subtitle text.
    func cleanSubtitleText(_ text: String) -> String {
        var cleaned = text

        // Strip ASS event prefix (up to 8 commas).
        let parts = cleaned.split(separator: ",", maxSplits: 10, omittingEmptySubsequences: false)
        if parts.count >= 9 {
            var commaCount = 0
            var cutIndex: String.Index?

            for (index, char) in cleaned.enumerated() {
                if char == "," {
                    commaCount += 1
                    if commaCount == 8 {
                        let nextIndex = cleaned.index(cleaned.startIndex, offsetBy: index + 1)
                        if nextIndex < cleaned.endIndex {
                            cutIndex = nextIndex
                        }
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
