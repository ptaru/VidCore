import XCTest
@testable import VidCore

final class BuffersTests: XCTestCase {
    func testPacketQueueSizeDefaults() {
        XCTAssertEqual(Buffers.auto.packetQueueSize, 15)
        XCTAssertEqual(Buffers.software.packetQueueSize, 15)
        XCTAssertEqual(Buffers.hardware.packetQueueSize, 120)
        XCTAssertEqual(Buffers.custom(frameBuffer: 5, packetQueue: 42).packetQueueSize, 42)
    }

    func testAutoResolvesBasedOnHardwareFlag() {
        let resolvedSoftware = Buffers.auto.resolved(isHardwareAccelerated: false)
        let resolvedHardware = Buffers.auto.resolved(isHardwareAccelerated: true)

        if case .software = resolvedSoftware {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected .software for non-accelerated")
        }

        if case .hardware = resolvedHardware {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected .hardware for accelerated")
        }
    }

    func testNonAutoResolvedIsIdentity() {
        let resolvedSoftware = Buffers.software.resolved(isHardwareAccelerated: true)
        let resolvedHardware = Buffers.hardware.resolved(isHardwareAccelerated: false)
        let resolvedCustom = Buffers.custom(frameBuffer: 1, packetQueue: 2).resolved(isHardwareAccelerated: true)

        if case .software = resolvedSoftware {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected .software to stay .software")
        }

        if case .hardware = resolvedHardware {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected .hardware to stay .hardware")
        }

        if case .custom(let frameBuffer, let packetQueue) = resolvedCustom {
            XCTAssertEqual(frameBuffer, 1)
            XCTAssertEqual(packetQueue, 2)
        } else {
            XCTFail("Expected .custom to stay .custom")
        }
    }
}
