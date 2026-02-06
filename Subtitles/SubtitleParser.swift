//
//  SubtitleParser.swift
//  VidCore
//
//  Parses subtitle text (SRT/ASS) into rich AttributedString.
//

import RegexBuilder
import SwiftUI

/// parser for converting raw subtitle text into styled AttributedString.
public enum SubtitleParser {

  /// Parses subtitle text into an AttributedString.
  /// - Parameters:
  ///   - text: The raw text from the subtitle frame.
  ///   - isASS: Whether the text is in ASS/SSA format.
  /// - Returns: An AttributedString with appropriate styling (bold, italic, color).
  public static func parse(_ text: String, isASS: Bool) -> AttributedString {
    if isASS {
      return parseASS(text)
    } else {
      // For non-ASS subtitles (rare, as FFmpeg usually converts),
      // we just treat as plain text. FFmpeg's subtitle decoder usually handles
      // styling via ASS, so if we get here with !isASS, it's likely basic text
      // (like mov_text from MP4) that doesn't use complex HTML-like tags.
      return AttributedString(text)
    }
  }

  // MARK: - State Structs

  private struct ASSStyleState {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var color: Color? = nil
  }

  // MARK: - ASS Parsing

  private static func parseASS(_ text: String) -> AttributedString {
    var attributed = AttributedString()

    var currentState = ASSStyleState()

    // Regex to find override blocks: { ... }
    let overrideBlock = Regex {
      "{"
      Capture {
        OneOrMore(.any, .reluctant)
      }
      "}"
    }

    // Regexes for commands inside the block
    // \b1, \b0
    let boldCmd = Regex {
      "\\b"
      Capture { One(.digit) }
    }
    // \i1, \i0
    let italicCmd = Regex {
      "\\i"
      Capture { One(.digit) }
    }
    // \u1, \u0
    let underlineCmd = Regex {
      "\\u"
      Capture { One(.digit) }
    }
    // \c&HBBGGRR& or \1c... simple color parser
    // Note: ASS relies on BGR order. &HBBGGRR&
    let colorCmd = Regex {
      ChoiceOf {
        "\\c"
        "\\1c"
      }
      "&H"
      Capture {
        OneOrMore(.hexDigit)
      }
      "&"
    }

    // Some ASS streams include stray HTML-like tags (e.g. "<font color=") before overrides.
    // Strip them to avoid leaking into rendered text.
    var cleaned = text.replacingOccurrences(of: "<font color=", with: "")
    cleaned = cleaned.replacingOccurrences(of: "</font>", with: "")

    var currentIndex = cleaned.startIndex

    while currentIndex < text.endIndex {
      // Find next override block
      if let match = try? overrideBlock.firstMatch(in: cleaned[currentIndex...]) {
        // Append text before block
        if match.range.lowerBound > currentIndex {
          let segment = cleaned[currentIndex..<match.range.lowerBound]
          attributed.append(applyASSStyle(segment, state: currentState))
        }

        // Parse commands inside the block
        let commands = match.1

        // Bold
        if let bMatch = try? boldCmd.firstMatch(in: commands) {
          currentState.isBold = (bMatch.1 == "1")
        }
        // Italic
        if let iMatch = try? italicCmd.firstMatch(in: commands) {
          currentState.isItalic = (iMatch.1 == "1")
        }
        // Underline
        if let uMatch = try? underlineCmd.firstMatch(in: commands) {
          currentState.isUnderline = (uMatch.1 == "1")
        }
        // Color
        if let cMatch = try? colorCmd.firstMatch(in: commands) {
          let bgrHex = String(cMatch.1)
          currentState.color = Color(assHex: bgrHex)
        }

        currentIndex = match.range.upperBound
      } else {
        // No more blocks
        let segment = cleaned[currentIndex...]
        attributed.append(applyASSStyle(segment, state: currentState))
        break
      }
    }

    return attributed
  }

  // MARK: - Helpers

  private static func applyASSStyle(_ text: Substring, state: ASSStyleState) -> AttributedString {
    var attr = AttributedString(String(text))
    if state.isBold { attr.font = .body.bold() }
    if state.isItalic { attr.font = (attr.font ?? .body).italic() }
    if state.isUnderline { attr.underlineStyle = .single }
    if let c = state.color { attr.foregroundColor = c }
    return attr
  }
}

// MARK: - Color Extension

extension Color {
  init?(assHex: String) {
    // ASS format: BBGGRR
    let hex = assHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)

    // Assuming 6 digits BGR
    if hex.count >= 6 {
      // Last 6 chars used usually if longer
      let b = Double((int >> 16) & 0xFF) / 255.0
      let g = Double((int >> 8) & 0xFF) / 255.0
      let r = Double(int & 0xFF) / 255.0
      self.init(red: r, green: g, blue: b)
    } else {
      return nil
    }
  }
}
