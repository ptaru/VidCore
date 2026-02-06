import XCTest
@testable import VidCore

final class TrackInfoTests: XCTestCase {
    func testAudioTrackDisplayNamesWithTitle() {
        let track = AudioTrackInfo(
            streamIndex: 2,
            language: "eng",
            title: "Director's Commentary",
            codecName: "aac",
            sampleRate: 48000,
            channels: 2
        )

        XCTAssertEqual(track.displayName, "Director's Commentary - ENG, AAC, 2ch")
        XCTAssertEqual(track.shortDisplayName, "ENG • AAC")
    }

    func testAudioTrackDisplayNamesWithoutTitleOrLanguage() {
        let track = AudioTrackInfo(
            streamIndex: 1,
            language: nil,
            title: nil,
            codecName: "opus",
            sampleRate: 48000,
            channels: 1
        )

        XCTAssertEqual(track.displayName, "Unknown, OPUS, 1ch")
        XCTAssertEqual(track.shortDisplayName, "OPUS")
    }

    func testSubtitleTrackDisplayNamesWithTitle() {
        let track = SubtitleTrackInfo(
            streamIndex: 3,
            language: "jpn",
            title: "Full Subtitles",
            codecName: "ass"
        )

        XCTAssertEqual(track.displayName, "Full Subtitles - JPN")
        XCTAssertEqual(track.shortDisplayName, "JPN")
    }

    func testSubtitleTrackDisplayNamesWithoutTitle() {
        let track = SubtitleTrackInfo(
            streamIndex: 4,
            language: nil,
            title: nil,
            codecName: "subrip"
        )

        XCTAssertEqual(track.displayName, "Unknown (SUBRIP)")
        XCTAssertEqual(track.shortDisplayName, "Unknown")
    }
}
