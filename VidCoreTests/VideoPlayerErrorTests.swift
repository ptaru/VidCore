import XCTest
@testable import VidCore

final class VideoPlayerErrorTests: XCTestCase {
    func testErrorDescriptions() {
        XCTAssertEqual(VideoPlayerError.fileNotFound.errorDescription, "Video file not found.")
        XCTAssertEqual(VideoPlayerError.decoderInitFailed("oops").errorDescription, "Failed to initialize decoder: oops")
        XCTAssertEqual(VideoPlayerError.unsupportedFormat.errorDescription, "Video format is not supported.")
        XCTAssertEqual(VideoPlayerError.decodingFailed("bad").errorDescription, "Decoding failed: bad")
        XCTAssertEqual(VideoPlayerError.seekFailed.errorDescription, "Failed to seek to the specified time.")
    }
}
