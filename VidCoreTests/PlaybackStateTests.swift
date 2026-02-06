import XCTest
@testable import VidCore

final class PlaybackStateTests: XCTestCase {
    func testErrorStateEquatability() {
        let stateA = PlaybackState.error(.fileNotFound)
        let stateB = PlaybackState.error(.fileNotFound)
        let stateC = PlaybackState.error(.seekFailed)

        XCTAssertEqual(stateA, stateB)
        XCTAssertNotEqual(stateA, stateC)
    }

    func testDistinctNonErrorStates() {
        XCTAssertNotEqual(PlaybackState.idle, .loading)
        XCTAssertNotEqual(PlaybackState.playing, .paused)
        XCTAssertNotEqual(PlaybackState.ready, .finished)
    }
}
