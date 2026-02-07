//
//  PacketQueue.swift
//  VidCore
//
//  Thread-safe packet queue for demuxer/decoder separation
//

import Foundation

/// Thread-safe packet queue using Swift actor for demuxer/decoder separation
/// Uses FFmpegPacketData from the ObjC bridge layer
public actor PacketQueue {
    private var packets: [FFmpegPacketData] = []
    public nonisolated let maxSize: Int
    private var waitingConsumers: [(UUID, CheckedContinuation<FFmpegPacketData?, Never>)] = []
    private var waitingProducers: [(UUID, CheckedContinuation<Void, Never>)] = []
    private var isClosed = false
    private var isSuspended = false
    
    public init(maxSize: Int = 15) {
        self.maxSize = maxSize
    }
    
    /// Pushes a packet to the queue.
    ///
    /// This method will wait if the queue is full (back-pressure).
    /// - Parameter packet: The packet to push.
    public func push(_ packet: FFmpegPacketData) async {
        guard !isClosed && !isSuspended else { return }
        
        while packets.count >= maxSize && !isClosed && !isSuspended {
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waitingProducers.append((waiterID, continuation))
                }
            } onCancel: {
                Task { await self.cancelProducer(waiterID) }
            }
        }
        
        guard !isClosed && !isSuspended else { return }
        
        if let (id, consumer) = waitingConsumers.first {
            waitingConsumers.removeFirst()
            _ = id
            consumer.resume(returning: packet)
        } else {
            packets.append(packet)
        }
    }
    
    /// Pops the next packet from the queue, waiting if empty.
    /// - Returns: The next packet, or `nil` if the queue is closed or suspended.
    public func pop() async -> FFmpegPacketData? {
        if !packets.isEmpty {
            let packet = packets.removeFirst()
            if let (_, producer) = waitingProducers.first {
                waitingProducers.removeFirst()
                producer.resume()
            }
            return packet
        }
        
        if isClosed || isSuspended {
            return nil
        }
        
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waitingConsumers.append((waiterID, continuation))
            }
        } onCancel: {
            Task { await self.cancelConsumer(waiterID) }
        }
    }
    
    /// Returns a packet from the queue without waiting.
    /// - Returns: The next packet, or `nil` if the queue is empty.
    public func tryPop() -> FFmpegPacketData? {
        guard !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        if let (_, producer) = waitingProducers.first {
            waitingProducers.removeFirst()
            producer.resume()
        }
        return packet
    }
    
    /// Closes the queue, waking all waiters.
    public func close() {
        isClosed = true
        
        for (_, consumer) in waitingConsumers {
            consumer.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        
        for (_, producer) in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Clears the queue and resets it for reuse.
    public func reset() {
        packets.removeAll()
        packets = []
        isClosed = false
        isSuspended = false
        
        for (_, consumer) in waitingConsumers {
            consumer.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        
        for (_, producer) in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Suspends the queue. Waiting operations will return immediately with `nil`.
    public func suspend() {
        isSuspended = true
        for (_, consumer) in waitingConsumers {
            consumer.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        for (_, producer) in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Resumes the queue.
    public func resume() {
        isSuspended = false
    }
    
    /// Whether the queue is currently suspended.
    public var suspended: Bool {
        isSuspended
    }
    
    /// The number of packets currently in the queue.
    public var count: Int {
        packets.count
    }
    
    /// Whether the queue is empty.
    public var isEmpty: Bool {
        packets.isEmpty
    }
    
    /// Whether the queue is full.
    public var isFull: Bool {
        packets.count >= maxSize
    }

    private func cancelProducer(_ id: UUID) {
        if let index = waitingProducers.firstIndex(where: { $0.0 == id }) {
            let (_, producer) = waitingProducers.remove(at: index)
            producer.resume()
        }
    }

    private func cancelConsumer(_ id: UUID) {
        if let index = waitingConsumers.firstIndex(where: { $0.0 == id }) {
            let (_, consumer) = waitingConsumers.remove(at: index)
            consumer.resume(returning: nil)
        }
    }
}
