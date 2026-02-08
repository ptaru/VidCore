import XCTest

@testable import VidCore

final class MediaPlayerErrorTests: XCTestCase {
    func testErrorDescriptions() {
        XCTAssertEqual(MediaPlayerError.fileNotFound.errorDescription, "Video file not found.")
        XCTAssertEqual(
            MediaPlayerError.decoderInitFailed("oops").errorDescription,
            "Failed to initialize decoder: oops")
        XCTAssertEqual(
            MediaPlayerError.unsupportedFormat.errorDescription, "Video format is not supported.")
        XCTAssertEqual(
            MediaPlayerError.decodingFailed("bad").errorDescription, "Decoding failed: bad")
        XCTAssertEqual(
            MediaPlayerError.seekFailed.errorDescription, "Failed to seek to the specified time.")
    }
}
