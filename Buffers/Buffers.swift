//
//  Buffers.swift
//  VidCore
//
//  Buffer configuration for video decoding and frame management
//

import Foundation

/// Buffer configuration preset for video decoding.
///
/// `Buffers` provides preset configurations for frame buffer and packet queue sizes,
/// optimized for hardware vs software decoding scenarios. Hardware decoding can afford
/// larger buffers, while software decoding requires more conservative memory usage.
///
/// ## Example
/// ```swift
/// let player = VideoPlayer(url: videoURL, buffers: .auto)      // Auto-detect decoder type
/// let player = VideoPlayer(url: videoURL, buffers: .hardware)  // Force hardware sizes
/// let player = VideoPlayer(url: videoURL, buffers: .custom(frameBuffer: 5, packetQueue: 50))
/// ```
public enum Buffers: Sendable {
    /// Automatically detect decoder type and use appropriate buffer sizes.
    case auto
    
    /// Conservative buffer sizes for software decoding.
    /// - Frame buffer: 3 frames
    /// - Packet queue: 15 packets
    case software
    
    /// Aggressive buffer sizes for hardware decoding.
    /// - Frame buffer: 10 frames
    /// - Packet queue: 120 packets
    case hardware
    
    /// Custom buffer sizes.
    case custom(frameBuffer: Int, packetQueue: Int)
    
    /// Size of the frame buffer in frames.
    public var frameBufferSize: Int {
        switch self {
        case .auto:
            // Default to software sizes for deferred initialization
            return Buffers.software.frameBufferSize
        case .software:
            return 3
        case .hardware:
            return 10
        case .custom(let frameBuffer, _):
            return frameBuffer
        }
    }
    
    /// Size of the packet queue in packets.
    public var packetQueueSize: Int {
        switch self {
        case .auto:
            // Default to software sizes for deferred initialization
            return Buffers.software.packetQueueSize
        case .software:
            return 15
        case .hardware:
            return 120
        case .custom(_, let packetQueue):
            return packetQueue
        }
    }
    
    /// Returns the appropriate buffer configuration based on hardware acceleration status.
    ///
    /// - Parameter isHardwareAccelerated: Whether hardware acceleration is available
    /// - Returns: The resolved buffer configuration
    public func resolved(isHardwareAccelerated: Bool) -> Buffers {
        switch self {
        case .auto:
            return isHardwareAccelerated ? .hardware : .software
        default:
            return self
        }
    }
}
