import CoreMedia
import CoreVideo
import XCTest

@testable import VidCore

final class VideoFrameTests: XCTestCase {
    private func makePixelBuffer(width: Int = 2, height: Int = 2) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary,
            &pixelBuffer
        )
        return pixelBuffer!
    }

    func testInitFromPixelBuffer() {
        let pixelBuffer = makePixelBuffer()
        let frame = VideoFrame(pixelBuffer: pixelBuffer, presentationTime: 1.5)

        XCTAssertNotNil(frame)
        XCTAssertFalse(frame!.isCompressed)
        XCTAssertEqual(frame!.presentationTime, 1.5)
        XCTAssertEqual(frame!.colorTransfer, 1)
    }

    func testInitFromPixelBufferHDRDefaultsToPQ() {
        let pixelBuffer = makePixelBuffer()
        let frame = VideoFrame(pixelBuffer: pixelBuffer, presentationTime: 0.0, isHDR: true)

        XCTAssertNotNil(frame)
        XCTAssertTrue(frame!.isHDR)
        XCTAssertEqual(frame!.colorTransfer, 16)
    }

    func testApplyHDRAttachmentsSetsExpectedKeys() {
        let pixelBuffer = makePixelBuffer()
        guard
            var frame = VideoFrame(
                pixelBuffer: pixelBuffer, presentationTime: 0.0, isHDR: true, colorTransfer: 18)
        else {
            XCTFail("Expected frame to be created")
            return
        }

        frame.applyHDRAttachments()

        let primaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
        let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)

        XCTAssertNotNil(primaries)
        XCTAssertNotNil(matrix)
        XCTAssertNotNil(transfer)
        XCTAssertEqual(transfer as! CFString, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
    }

    func testApplyHDRAttachmentsNoOpWhenNotHDR() {
        let pixelBuffer = makePixelBuffer()
        guard var frame = VideoFrame(pixelBuffer: pixelBuffer, presentationTime: 0.0, isHDR: false)
        else {
            XCTFail("Expected frame to be created")
            return
        }

        frame.applyHDRAttachments()

        let primaries = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil)
        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)
        XCTAssertNil(primaries)
        XCTAssertNil(transfer)
    }
}
