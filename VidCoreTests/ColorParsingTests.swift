import SwiftUI
import XCTest

@testable import VidCore

final class ColorParsingTests: XCTestCase {
  // Color(hex:) was removed with SRT parser.
  // func testHexColorParsesValidLengths() { ... }
  // func testHexColorRejectsInvalidLengths() { ... }

  func testASSColorParsesValidBGR() {
    XCTAssertNotNil(Color(assHex: "00FF00"))
    XCTAssertNotNil(Color(assHex: "FF00FF"))
  }

  func testASSColorRejectsTooShort() {
    XCTAssertNil(Color(assHex: "FF"))
    XCTAssertNil(Color(assHex: "12345"))
  }
}
