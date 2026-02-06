import SwiftUI
import XCTest

@testable import VidCore

final class SubtitleParserTests: XCTestCase {
  func testParseNonASSIsPlainText() {
    let input = "Hello world"
    let output = SubtitleParser.parse(input, isASS: false)
    XCTAssertEqual(String(output.characters), "Hello world")
  }

  func testParseNonASSDoesNotStripTags() {
    // Since we removed the SRT parser, tags should appear as-is in the text
    let input = "<b>Bold</b>"
    let output = SubtitleParser.parse(input, isASS: false)
    XCTAssertEqual(String(output.characters), "<b>Bold</b>")

    // Verify no bold attribute (or any font attribute) was applied
    let hasFontAttribute = output.runs.contains { run in
      run.font != nil
    }
    XCTAssertFalse(hasFontAttribute)
  }

  func testParseASSItalicAndUnderlineOverrides() {
    let input = "{\\i1}Italic{\\i0} {\\u1}Under{\\u0}"
    let output = SubtitleParser.parse(input, isASS: true)
    let rendered = String(output.characters)
    XCTAssertEqual(rendered, "Italic Under")
  }

  func testParseASSUnknownOverrideIsIgnored() {
    let input = "{\\unknown1}Text"
    let output = SubtitleParser.parse(input, isASS: true)
    let rendered = String(output.characters)
    XCTAssertEqual(rendered, "Text")
  }

  func testParseASSStripsMalformedFontTagPrefix() {
    let input = "<font color={\\c&HFF0000&}A{\\c}"
    let output = SubtitleParser.parse(input, isASS: true)
    let rendered = String(output.characters)
    XCTAssertEqual(rendered, "A")
    XCTAssertFalse(rendered.contains("<"))
  }
}
