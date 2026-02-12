import XCTest

@testable import VidCore

final class PacketQueueTests: XCTestCase {
    private func makePacket(pts: Int64) -> FFmpegDemuxerPacket {
        let packet = FFmpegDemuxerPacket()
        packet.data = Data([0x01, 0x02, 0x03])
        packet.size = Int64(packet.data.count)
        packet.pts = pts
        packet.dts = pts
        packet.duration = 1
        packet.isVideo = true
        packet.isAudio = false
        packet.isSubtitle = false
        packet.isKeyframe = false
        return packet
    }

    func testPushPopOrder() async {
        let queue = PacketQueue(maxSize: 2)
        let first = makePacket(pts: 1)
        let second = makePacket(pts: 2)

        await queue.push(first)
        await queue.push(second)

        let poppedFirst = await queue.pop()
        let poppedSecond = await queue.pop()

        XCTAssertEqual(poppedFirst?.pts, 1)
        XCTAssertEqual(poppedSecond?.pts, 2)
        let isEmpty = await queue.isEmpty
        XCTAssertTrue(isEmpty)
    }

    func testTryPopReturnsNilWhenEmpty() async {
        let queue = PacketQueue(maxSize: 1)
        let popped = await queue.tryPop()
        XCTAssertNil(popped)
    }

    func testCloseUnblocksPop() async {
        let queue = PacketQueue(maxSize: 1)
        let task = Task { await queue.pop() }

        await queue.close()
        let result = await task.value

        XCTAssertNil(result)
        let isEmpty = await queue.isEmpty
        XCTAssertTrue(isEmpty)
    }

    func testSuspendMakesPopReturnNilWhenEmpty() async {
        let queue = PacketQueue(maxSize: 1)
        await queue.suspend()

        let result = await queue.pop()
        XCTAssertNil(result)
        let isSuspended = await queue.suspended
        XCTAssertTrue(isSuspended)
    }

    func testBackpressureBlocksProducerUntilPop() async {
        let queue = PacketQueue(maxSize: 1)
        let first = makePacket(pts: 1)
        let second = makePacket(pts: 2)

        await queue.push(first)

        let notCompletedYet = expectation(description: "second push not completed yet")
        notCompletedYet.isInverted = true
        let pushCompleted = expectation(description: "second push completed")
        let pushTask = Task {
            await queue.push(second)
            pushCompleted.fulfill()
        }

        let earlyResult = XCTWaiter().wait(for: [notCompletedYet], timeout: 0.1)
        XCTAssertEqual(earlyResult, .completed)

        _ = await queue.pop()
        let finalResult = XCTWaiter().wait(for: [pushCompleted], timeout: 1.0)
        XCTAssertEqual(finalResult, .completed)

        _ = await pushTask.value

        let count = await queue.count
        XCTAssertEqual(count, 1)
        let popped = await queue.pop()
        XCTAssertEqual(popped?.pts, 2)
    }

    func testSuspendDropsPushesUntilResume() async {
        let queue = PacketQueue(maxSize: 2)
        await queue.suspend()

        await queue.push(makePacket(pts: 1))
        let countWhileSuspended = await queue.count
        XCTAssertEqual(countWhileSuspended, 0)

        await queue.resume()
        await queue.push(makePacket(pts: 2))
        let countAfterResume = await queue.count
        XCTAssertEqual(countAfterResume, 1)
    }

    func testResetUnblocksWaitingConsumer() async {
        let queue = PacketQueue(maxSize: 1)
        let popReturned = expectation(description: "pop returned after reset")
        let popTask = Task {
            let result = await queue.pop()
            XCTAssertNil(result)
            popReturned.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        await queue.reset()

        await fulfillment(of: [popReturned], timeout: 1.0)
        _ = await popTask.value
    }

    func testCancelledConsumerDoesNotHang() async {
        let queue = PacketQueue(maxSize: 1)
        let popTask = Task { await queue.pop() }
        popTask.cancel()

        let result = await popTask.value
        XCTAssertNil(result)

        await queue.push(makePacket(pts: 10))
        let popped = await queue.pop()
        XCTAssertEqual(popped?.pts, 10)
    }
}
