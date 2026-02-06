import XCTest
@testable import VidCore

final class VideoInfoTests: XCTestCase {
    func testTransferFunctionName() {
        let info709 = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorTransfer: 1
        )
        XCTAssertEqual(info709.transferFunctionName, "BT.709")

        let infoPQ = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorTransfer: 16
        )
        XCTAssertEqual(infoPQ.transferFunctionName, "PQ")

        let infoHLG = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorTransfer: 18
        )
        XCTAssertEqual(infoHLG.transferFunctionName, "HLG")

        let infoUnknown = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorTransfer: 5
        )
        XCTAssertEqual(infoUnknown.transferFunctionName, "Unknown")

        let infoUnspecified = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorTransfer: 0
        )
        XCTAssertEqual(infoUnspecified.transferFunctionName, "Unspecified")
    }

    func testColorPrimariesName() {
        let info709 = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorPrimaries: 1
        )
        XCTAssertEqual(info709.colorPrimariesName, "BT.709")

        let info2020 = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorPrimaries: 9
        )
        XCTAssertEqual(info2020.colorPrimariesName, "BT.2020")

        let infoUnknown = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorPrimaries: 5
        )
        XCTAssertEqual(infoUnknown.colorPrimariesName, "Unknown")

        let infoUnspecified = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorPrimaries: 0
        )
        XCTAssertEqual(infoUnspecified.colorPrimariesName, "Unspecified")
    }

    func testColorSpaceName() {
        let info709 = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorSpace: 1
        )
        XCTAssertEqual(info709.colorSpaceName, "BT.709")

        let info2020 = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorSpace: 9
        )
        XCTAssertEqual(info2020.colorSpaceName, "BT.2020nc")

        let infoUnknown = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorSpace: 4
        )
        XCTAssertEqual(infoUnknown.colorSpaceName, "Unspecified")

        let infoYCbCr = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, colorSpace: 0
        )
        XCTAssertEqual(infoYCbCr.colorSpaceName, "YCbCr")
    }

    func testContentPeakNitsFallbacks() {
        let infoMaxCLL = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, maxContentLightLevel: 1500
        )
        XCTAssertEqual(infoMaxCLL.contentPeakNits, 1500)

        let infoMastering = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false, maxContentLightLevel: 0,
            masteringDisplayMaxLuminance: 2000
        )
        XCTAssertEqual(infoMastering.contentPeakNits, 2000)

        let infoDefault = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false
        )
        XCTAssertEqual(infoDefault.contentPeakNits, 1000)
    }

    func testAudioAndSubtitleTrackDefaults() {
        let info = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false
        )

        XCTAssertEqual(info.audioTracks.count, 0)
        XCTAssertEqual(info.subtitleTracks.count, 0)
        XCTAssertNil(info.audioCodecName)
        XCTAssertNil(info.audioSampleRate)
        XCTAssertNil(info.audioChannels)
    }

    func testAudioAndSubtitleTrackListsAreStored() {
        let audioTrack = AudioTrackInfo(
            streamIndex: 0,
            language: "eng",
            title: nil,
            codecName: "aac",
            sampleRate: 48000,
            channels: 2
        )
        let subtitleTrack = SubtitleTrackInfo(
            streamIndex: 1,
            language: "spa",
            title: "Full",
            codecName: "ass"
        )

        let info = VideoInfo(
            width: 1, height: 1, frameRate: 24, duration: 1,
            containerName: "test", codecName: "h264",
            isHardwareAccelerated: false,
            audioTracks: [audioTrack],
            subtitleTracks: [subtitleTrack]
        )

        XCTAssertEqual(info.audioTracks, [audioTrack])
        XCTAssertEqual(info.subtitleTracks, [subtitleTrack])
    }
}
