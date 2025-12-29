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
    private let maxSize: Int
    private var waitingConsumers: [CheckedContinuation<FFmpegPacketData?, Never>] = []
    private var waitingProducers: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    private var isSuspended = false
    
    public init(maxSize: Int = 15) {
        self.maxSize = maxSize
    }
    
    /// Push a packet to the queue
    /// Will wait if the queue is full (back-pressure)
    public func push(_ packet: FFmpegPacketData) async {
        // If closed or suspended, discard
        guard !isClosed && !isSuspended else { return }
        
        // Wait if queue is full
        while packets.count >= maxSize && !isClosed && !isSuspended {
            await withCheckedContinuation { continuation in
                waitingProducers.append(continuation)
            }
        }
        
        guard !isClosed && !isSuspended else { return }
        
        // If a consumer is waiting, give them the packet directly
        if let consumer = waitingConsumers.first {
            waitingConsumers.removeFirst()
            consumer.resume(returning: packet)
        } else {
            packets.append(packet)
        }
    }
    
    /// Pop the next packet, waiting if empty
    /// Returns nil if the queue is closed or suspended and empty
    public func pop() async -> FFmpegPacketData? {
        // Return immediately if we have packets
        if !packets.isEmpty {
            let packet = packets.removeFirst()
            // Wake a waiting producer if any
            if let producer = waitingProducers.first {
                waitingProducers.removeFirst()
                producer.resume()
            }
            return packet
        }
        
        // Return nil if closed or suspended
        if isClosed || isSuspended {
            return nil
        }
        
        // Wait for a packet
        return await withCheckedContinuation { continuation in
            waitingConsumers.append(continuation)
        }
    }
    
    /// Pop without waiting - returns nil if empty
    public func tryPop() -> FFmpegPacketData? {
        guard !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        if let producer = waitingProducers.first {
            waitingProducers.removeFirst()
            producer.resume()
        }
        return packet
    }
    
    /// Close the queue, waking all waiters
    public func close() {
        isClosed = true
        
        // Wake all waiting consumers with nil
        for consumer in waitingConsumers {
            consumer.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        
        // Wake all waiting producers
        for producer in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Clear the queue and reset for reuse
    public func reset() {
        packets.removeAll()
        packets = []  // Reset capacity to zero, releasing all packet data
        isClosed = false
        isSuspended = false
        
        // Wake waiters
        for consumer in waitingConsumers {
            consumer.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        
        for producer in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Suspend the queue - waiting operations return immediately
    /// Packets are preserved in the queue
    public func suspend() {
        isSuspended = true
        // Wake waiting consumers with nil
        for consumer in waitingConsumers {
            consumer.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        // Wake waiting producers
        for producer in waitingProducers {
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
}
