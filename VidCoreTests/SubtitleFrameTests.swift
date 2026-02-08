import CoreGraphics
import XCTest

@testable import VidCore

final class SubtitleFrameTests: XCTestCase {
    func testDurationIsComputedFromStartAndEnd() {
        let frame = SubtitleFrame(content: .text("Hi"), startTime: 1.0, endTime: 3.5)
        XCTAssertEqual(frame.duration, 2.5)
    }

    func testDurationIsNilWhenEndMissing() {
        let frame = SubtitleFrame(content: .text("Hi"), startTime: 1.0, endTime: nil)
        XCTAssertNil(frame.duration)
    }

    func testBitmapEquatability() {
        let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let data = Data([0x00, 0x01])
        let bitmapA = SubtitleBitmap(data: data, width: 2, height: 1, rect: rect)
        let bitmapB = SubtitleBitmap(data: data, width: 2, height: 1, rect: rect)
        XCTAssertEqual(bitmapA, bitmapB)
    }
}
