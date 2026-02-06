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
    
    /// Push a packet to the queue
    /// Will wait if the queue is full (back-pressure)
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
    
    /// Pop the next packet, waiting if empty
    /// Returns nil if the queue is closed or suspended and empty
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
    
    /// Pop without waiting - returns nil if empty
    public func tryPop() -> FFmpegPacketData? {
        guard !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        if let (_, producer) = waitingProducers.first {
            waitingProducers.removeFirst()
            producer.resume()
        }
        return packet
    }
    
    /// Close the queue, waking all waiters
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
    
    /// Clear the queue and reset for reuse
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
    
    /// Suspend the queue - waiting operations return immediately
    /// Packets are preserved in the queue
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
    
    /// Resume the queue - waiting operations will block again
    public func resume() {
        isSuspended = false
    }
    
    /// Whether the queue is currently suspended
    public var suspended: Bool {
        isSuspended
    }
    
    public var count: Int {
        packets.count
    }
    
    public var isEmpty: Bool {
        packets.isEmpty
    }
    
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
