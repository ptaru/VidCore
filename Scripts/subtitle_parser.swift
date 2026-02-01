import RegexBuilder
import SwiftUI

// MARK: - SubtitleParser Code (Copied)
// Note: In a real project with proper module structure, we would import VidCore.
// For this script to run standalone, we include the necessary parts.

public enum SubtitleParser {

  public static func parse(_ text: String, isASS: Bool) -> AttributedString {
    if isASS {
      return parseASS(text)
    } else {
      return parseSRT(text)
    }
  }

  // MARK: - State Structs

  private struct SRTStyleState {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var color: Color? = nil
  }

  private struct ASSStyleState {
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var color: Color? = nil
  }

  // MARK: - SRT Parsing

  private enum SRTToken {
    case text(Substring)
    case boldStart, boldEnd
    case italicStart, italicEnd
    case underlineStart, underlineEnd
    case fontColorStart(Color), fontEnd
  }

  private static func parseSRT(_ text: String) -> AttributedString {
    var attributed = AttributedString()

    var styleStack: [SRTStyleState] = [SRTStyleState()]

    func currentStyle() -> SRTStyleState {
      styleStack.last ?? SRTStyleState()
    }

    // Regexdefinitions
    let boldStart = Regex { "<b>" }
    let boldEnd = Regex { "</b>" }
    let italicStart = Regex { "<i>" }
    let italicEnd = Regex { "</i>" }
    let underlineStart = Regex { "<u>" }
    let underlineEnd = Regex { "</u>" }
    let fontEnd = Regex { "</font>" }

    // <font color="#RRGGBB">
    let fontColorStart = Regex {
      "<font color=\""
      Capture {
        OneOrMore(.hexDigit)
      }
      "\">"
    }

    var currentIndex = text.startIndex

    while currentIndex < text.endIndex {
      if let tagStart = text[currentIndex...].firstIndex(of: "<") {
        if tagStart > currentIndex {
          let segment = text[currentIndex..<tagStart]
          attributed.append(applySRTStyle(segment, state: currentStyle()))
        }

        let remaining = text[tagStart...]

        if let match = try? boldStart.prefixMatch(in: remaining) {
          var newState = currentStyle()
          newState.isBold = true
          styleStack.append(newState)
          currentIndex = match.range.upperBound
        } else if let match = try? boldEnd.prefixMatch(in: remaining) {
          if styleStack.count > 1 { styleStack.removeLast() }
          currentIndex = match.range.upperBound
        } else if let match = try? italicStart.prefixMatch(in: remaining) {
          var newState = currentStyle()
          newState.isItalic = true
          styleStack.append(newState)
          currentIndex = match.range.upperBound
        } else if let match = try? italicEnd.prefixMatch(in: remaining) {
          if styleStack.count > 1 { styleStack.removeLast() }
          currentIndex = match.range.upperBound
        } else if let match = try? underlineStart.prefixMatch(in: remaining) {
          var newState = currentStyle()
          newState.isUnderline = true
          styleStack.append(newState)
          currentIndex = match.range.upperBound
        } else if let match = try? underlineEnd.prefixMatch(in: remaining) {
          if styleStack.count > 1 { styleStack.removeLast() }
          currentIndex = match.range.upperBound
        } else if let match = try? fontColorStart.prefixMatch(in: remaining) {
          let hexString = String(match.1)
          var newState = currentStyle()
          newState.color = Color(hex: hexString)
          styleStack.append(newState)
          currentIndex = match.range.upperBound
        } else if let match = try? fontEnd.prefixMatch(in: remaining) {
          if styleStack.count > 1 { styleStack.removeLast() }
          currentIndex = match.range.upperBound
        } else {
          attributed.append(applySRTStyle("<", state: currentStyle()))
          currentIndex = text.index(after: tagStart)
        }
      } else {
        let segment = text[currentIndex...]
        attributed.append(applySRTStyle(segment, state: currentStyle()))
        break
      }
    }

    return attributed
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
    let boldCmd = Regex {
      "\\b"
      Capture { One(.digit) }
    }
    let italicCmd = Regex {
      "\\i"
      Capture { One(.digit) }
    }
    let underlineCmd = Regex {
      "\\u"
      Capture { One(.digit) }
    }
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

    var currentIndex = text.startIndex

    while currentIndex < text.endIndex {
      // Find next override block
      if let match = try? overrideBlock.firstMatch(in: text[currentIndex...]) {
        // Append text before block
        if match.range.lowerBound > currentIndex {
          let segment = text[currentIndex..<match.range.lowerBound]
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
        let segment = text[currentIndex...]
        attributed.append(applyASSStyle(segment, state: currentState))
        break
      }
    }

    return attributed
  }

  // MARK: - Helpers

  private static func applySRTStyle(_ text: Substring, state: SRTStyleState) -> AttributedString {
    var attr = AttributedString(String(text))
    if state.isBold { attr.font = .body.bold() }
    if state.isItalic { attr.font = (attr.font ?? .body).italic() }
    if state.isUnderline { attr.underlineStyle = .single }
    if let c = state.color { attr.foregroundColor = c }
    return attr
  }

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
  init?(hex: String) {
    let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)
    let r: UInt64
    let g: UInt64
    let b: UInt64
    switch hex.count {
    case 3:  // RGB (12-bit)
      (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
    case 6:  // RGB (24-bit)
      (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
    default:
      return nil
    }
    self.init(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
  }

  init?(assHex: String) {
    let hex = assHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var int: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&int)

    if hex.count >= 6 {
      let b = Double((int >> 16) & 0xFF) / 255.0
      let g = Double((int >> 8) & 0xFF) / 255.0
      let r = Double(int & 0xFF) / 255.0
      self.init(red: r, green: g, blue: b)
    } else {
      return nil
    }
  }
}

// MARK: - Tests

func runTests() {
  print("Running Verification Tests...")

  // Test 1: SRT Basic
  let srt1 = "Hello <b>World</b>"
  let attr1 = SubtitleParser.parse(srt1, isASS: false)
  print("\n--- Test 1 [SRT Basic] ---")
  print("Input: \(srt1)")
  print("Output Description: \(String(describing: attr1))")

  // Test 2: SRT Nested
  let srt2 = "<b>Bold <i>Bi</i></b>"
  let attr2 = SubtitleParser.parse(srt2, isASS: false)
  print("\n--- Test 2 [SRT Nested] ---")
  print("Input: \(srt2)")
  print("Output Description: \(String(describing: attr2))")

  // Test 3: ASS Basic
  let ass1 = "{\\b1}Bold{\\b0} Normal"
  let attr3 = SubtitleParser.parse(ass1, isASS: true)
  print("\n--- Test 3 [ASS Basic] ---")
  print("Input: \(ass1)")
  print("Output Description: \(String(describing: attr3))")

  // Test 4: ASS Color
  let ass2 = "{\\c&H0000FF&}Red"
  let attr4 = SubtitleParser.parse(ass2, isASS: true)
  print("\n--- Test 4 [ASS Color] ---")
  print("Input: \(ass2)")
  print("Output Description: \(String(describing: attr4))")
}

runTests()
