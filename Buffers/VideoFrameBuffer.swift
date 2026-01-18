//
//  VideoFrameBuffer.swift
//  VidCore
//
//  Thread-safe frame buffer using Swift actor with async waiting
//

import Foundation

/// Thread-safe buffer for video frames using Swift actor
/// Supports async waiting for frames to avoid busy-polling
/// Frames are stored in PTS order to handle multi-threaded decoders that may
/// return frames in decode order rather than presentation order
public actor VideoFrameBuffer {
    private var frames: [VideoFrame] = []
    private let maxSize: Int
    private var waitingConsumers: [CheckedContinuation<VideoFrame?, Never>] = []
    private var availabilityWaiters: [CheckedContinuation<Void, Never>] = []
    private var waitingProducers: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    private var isSuspended = false
    
    /// Minimum number of frames to buffer before yielding to display loop
    /// This allows time for out-of-order frames to arrive and be reordered
    /// Larger values = better reordering but higher latency
    private let reorderDelay: Int = 1
    
    public init(maxSize: Int = 3) {
        self.maxSize = maxSize
    }
    
    /// Push a frame to the buffer in presentation time order
    /// Frames are inserted sorted by PTS to handle out-of-order decode
    public func push(_ frame: VideoFrame) {
        insertSorted(frame)
        
        // Wake availability waiters if we have enough frames
        if !availabilityWaiters.isEmpty && frames.count >= reorderDelay {
            for waiter in availabilityWaiters {
                waiter.resume()
            }
            availabilityWaiters.removeAll()
        }
        
        // If someone is waiting AND we have enough frames for reordering, wake them
        if let continuation = waitingConsumers.first, frames.count >= reorderDelay {
            waitingConsumers.removeFirst()
            if let first = frames.first {
                frames.removeFirst()
                continuation.resume(returning: first)
                if let producer = waitingProducers.first {
                    waitingProducers.removeFirst()
                    producer.resume()
                }
            } else {
                continuation.resume(returning: nil)
            }
        }
        
        // Remove oldest frames if buffer is full
        while frames.count > maxSize {
            frames.removeFirst()
        }
    }
    
    /// Insert a frame in sorted PTS order (binary insertion for efficiency)
    private func insertSorted(_ frame: VideoFrame) {
        var low = 0
        var high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].presentationTime < frame.presentationTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        frames.insert(frame, at: low)
    }
    
    /// Wait until buffer has space, then push the frame
    /// This provides back-pressure without polling
    public func pushWithBackpressure(_ frame: VideoFrame) async {
        while frames.count >= maxSize && !isClosed && !isSuspended {
            await withCheckedContinuation { continuation in
                waitingProducers.append(continuation)
            }
        }
        
        guard !isClosed && !isSuspended else { return }
        push(frame)
    }
    
    /// Pop and return the next frame, or nil if empty
    public func pop() -> VideoFrame? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        // Wake a waiting producer if any
        if let producer = waitingProducers.first {
            waitingProducers.removeFirst()
            producer.resume()
        }
        return frame
    }
    
    /// Pop with peek - returns (frame, nextFramePTS) in one call to reduce async overhead
    /// nextFramePTS is the PTS of the next frame after popping, or nil if buffer becomes empty
    public func popWithNext() -> (frame: VideoFrame, nextPTS: Double?)? {
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        let nextPTS = frames.first?.presentationTime
        // Wake a waiting producer if any
        if let producer = waitingProducers.first {
            waitingProducers.removeFirst()
            producer.resume()
        }
        return (frame, nextPTS)
    }
    
    /// Peek at the next frame without removing it
    public func peek() -> VideoFrame? {
        return frames.first
    }
    
    /// Wait until a frame is available without consuming it
    /// Returns true if a frame is ready, false if the buffer was closed/suspended with no remaining frames
    /// Respects the reorder delay unless the buffer is closed (then flushes remaining frames)
    public func waitForFrameAvailable() async -> Bool {
        if frames.count >= reorderDelay || (isClosed && !frames.isEmpty) {
            return true
        }
        
        if (isClosed || isSuspended) && frames.isEmpty {
            return false
        }
        
        if isSuspended {
            return false
        }
        
        await withCheckedContinuation { continuation in
            availabilityWaiters.append(continuation)
        }
        
        return !frames.isEmpty
    }
    
    /// Wait for the next frame asynchronously and consume it
    /// Returns nil when the buffer is closed
    public func waitForFrame() async -> VideoFrame? {
        if !frames.isEmpty {
            let frame = frames.removeFirst()
            if let producer = waitingProducers.first {
                waitingProducers.removeFirst()
                producer.resume()
            }
            return frame
        }
        
        if isClosed {
            return nil
        }
        
        return await withCheckedContinuation { continuation in
            waitingConsumers.append(continuation)
        }
    }
    
    /// Clear all buffered frames and cancel waiting consumers
    public func clear() {
        frames.removeAll()
        for continuation in waitingConsumers {
            continuation.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        for waiter in availabilityWaiters {
            waiter.resume()
        }
        availabilityWaiters.removeAll()
        for producer in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Close the buffer, signaling no more frames will arrive
    /// Remaining frames will still be yielded to consumers (without waiting for reorder delay)
    public func close() {
        isClosed = true
        
        for waiter in availabilityWaiters {
            waiter.resume()
        }
        availabilityWaiters.removeAll()
        
        while let continuation = waitingConsumers.first, let frame = frames.first {
            waitingConsumers.removeFirst()
            frames.removeFirst()
            continuation.resume(returning: frame)
        }
        
        for continuation in waitingConsumers {
            continuation.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        
        for producer in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Reset the buffer for reuse (e.g., after seek)
    public func reset() {
        frames.removeAll()
        frames = []
        isClosed = false
        isSuspended = false
        for continuation in waitingConsumers {
            continuation.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        for waiter in availabilityWaiters {
            waiter.resume()
        }
        availabilityWaiters.removeAll()
        for producer in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Suspend the buffer - waiting operations return immediately without blocking
    /// Frames are preserved in the buffer
    public func suspend() {
        isSuspended = true
        for continuation in waitingConsumers {
            continuation.resume(returning: nil)
        }
        waitingConsumers.removeAll()
        for waiter in availabilityWaiters {
            waiter.resume()
        }
        availabilityWaiters.removeAll()
        for producer in waitingProducers {
            producer.resume()
        }
        waitingProducers.removeAll()
    }
    
    /// Resume the buffer - waiting operations will block again
    public func resume() {
        isSuspended = false
    }
    
    /// Whether the buffer is currently suspended
    public var suspended: Bool {
        isSuspended
    }
    
    public var count: Int {
        frames.count
    }
    
    public var isEmpty: Bool {
        frames.isEmpty
    }
    
    public var isFull: Bool {
        frames.count >= maxSize
    }
}
