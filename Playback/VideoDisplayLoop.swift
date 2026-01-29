//
//  VideoDisplayLoop.swift
//  VidCore
//
//  Decoupled display loop running on a background actor
//

import Foundation
import QuartzCore
import AVFoundation

/// Actor responsible for the video display loop.
/// It consumes frames from the buffer, synchronizes with audio, and pushes to the renderer.
public actor VideoDisplayLoop {
    
    // MARK: - Dependencies
    private let frameBuffer: VideoFrameBuffer
    private let packetQueue: PacketQueue
    private let audioPlayer: AudioPlayer
    private weak var renderer: VideoRendererTarget?
    
    // MARK: - State
    private var isRunning = false
    private var loopTask: Task<Void, Never>?
    
    // Timing state
    private var playbackStartTime: CFTimeInterval = 0
    private var pauseTimestamp: CFTimeInterval = 0
    private var firstFramePTS: Double = 0
    private var audioStartOffset: Double = 0
    
    // Cached info
    private var frameRate: Double = 30.0
    private var isHardware: Bool = false
    private var decoderName: String = "Unknown"
    
    // Sync state
    private var consecutiveDriftCount: Int = 0
    
    // Callback for debug stats
    private var statsUpdateHandler: (@MainActor @Sendable (PlayerDebugStats) -> Void)?
    private var frameUpdateHandler: (@MainActor @Sendable (VideoFrame) -> Void)?
    private var completionHandler: (@MainActor @Sendable () -> Void)?
    
    // Constants
    private enum Constants {
        static let displayLoopInterval: UInt64 = 8_000_000     // 8ms
        static let driftWarningThreshold: Double = 0.05        // 50ms
        static let driftCorrectionThreshold: Double = 0.15     // 150ms
        static let severeDriftThreshold: Double = 1.0          // 1s
        static let severeDriftCountThreshold: Int = 5
        static let consecutiveDriftCountThreshold: Int = 3
    }
    
    public init(frameBuffer: VideoFrameBuffer, packetQueue: PacketQueue, audioPlayer: AudioPlayer) {
        self.frameBuffer = frameBuffer
        self.packetQueue = packetQueue
        self.audioPlayer = audioPlayer
    }
    
    public func setRenderer(_ target: VideoRendererTarget?) {
        self.renderer = target
    }
    
    public func setVideoInfo(_ info: VideoInfo?) {
        self.frameRate = info?.frameRate ?? 30.0
        self.isHardware = info?.isHardwareAccelerated ?? false
        self.decoderName = info?.decoderName ?? "Unknown"
    }
    
    public func reset() {
        // Reset state so next frame triggers new start time calculation
        isRunning = false // Stop loop if valid? No, reset often implies valid after seek.
        // Actually, seek pauses first. 
        // Just resetting timing variables
        // We will toggle isRunning separately via start/stop/pause
    }
    
    /// Called when seeking to clear timing state
    public func resetTiming() {
        // Force recalculation of playback start time on next frame
        // We do this by setting a flag or just relying on "hasStarted" inside the loop?
        // Accessing 'hasStarted' inside loop is local variable.
        // We can't change local var from outside.
        // We need to restart the loop or share state.
        
        // Better approach: stop the loop, clearing the local variables is automatic when loop restarts?
        // My loop implementation uses `var hasStarted = false` inside `runLoop`.
        // So stopping and starting the loop resets state.
        // Since seek calls pause (which calls stop), restarting will reset state.
        // So explicit reset might not be needed if seek stops the loop.
    }
    
    public func setStatsHandler(_ handler: @escaping @MainActor @Sendable (PlayerDebugStats) -> Void) {
        self.statsUpdateHandler = handler
    }
    
    public func setFrameUpdateHandler(_ handler: @escaping @MainActor @Sendable (VideoFrame) -> Void) {
        self.frameUpdateHandler = handler
    }
    
    public func setCompletionHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.completionHandler = handler
    }
    
    // MARK: - Control
    
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }
    
    public func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
    }
    
    public func pause() {
        // Just stop the loop, resume will restart
        stop()
    }
    
    /// Manually display a frame (e.g. after seeking while paused)
    public func displayFrame(_ frame: VideoFrame) {
        renderer?.enqueue(frame)
        
        // Fire frame update to mirror
        if let frameHandler = frameUpdateHandler {
            Task { @MainActor in
                frameHandler(frame)
            }
        }
    }
    
    // MARK: - Loop
    
    private func runLoop() async {
        var hasStarted = false
        var droppedFrameCount = 0
        var reachedEndOfStream = false
        
        while !Task.isCancelled && isRunning {
            if await frameBuffer.suspended {
                try? await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            
            // Wait for frame
            let frameAvailable = await frameBuffer.waitForFrameAvailable()
            guard frameAvailable else {
                 if await frameBuffer.suspended { continue }
                 reachedEndOfStream = true
                 break // Buffer closed/empty
            }
            
            // Peek next frame
            guard let nextFrame = await frameBuffer.peek() else { continue }
            
            if !hasStarted {
                playbackStartTime = CACurrentMediaTime()
                firstFramePTS = nextFrame.presentationTime
                hasStarted = true
            }
            
            // Calculate timing
            let currentPlaybackTime: Double
            // Use thread-safe media time
            if await audioPlayer.hasBufferedAudio && audioPlayer.isPlaying {
                currentPlaybackTime = audioPlayer.getMediaTime()
            } else {
                currentPlaybackTime = (CACurrentMediaTime() - playbackStartTime) + firstFramePTS
            }
            
            let waitTime = nextFrame.presentationTime - currentPlaybackTime
            
            // Sync Logic
            if await audioPlayer.hasBufferedAudio && audioPlayer.isPlaying {
                let drift = waitTime
                if abs(drift) > Constants.driftWarningThreshold {
                    consecutiveDriftCount += 1
                    // Logic for heavy drift could trigger re-sync (simplified here)
                } else {
                    consecutiveDriftCount = 0
                }
            }
            
            // Wait or Drop
            if waitTime > 0.1 {
                try? await Task.sleep(nanoseconds: Constants.displayLoopInterval)
                continue
            } else if waitTime > 0 {
                let waitNanos = UInt64(waitTime * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNanos)
            } else {
                let frameDuration = 1.0 / frameRate
                if waitTime < -frameDuration {
                    // Late frame, drop
                    _ = await frameBuffer.pop()
                    droppedFrameCount += 1
                    continue
                }
            }
            
            // Display
            if let frame = await frameBuffer.pop() {
                renderer?.enqueue(frame)
                
                // Fire and forget frame update to MainActor (for debug/UI mirror)
                if let frameHandler = frameUpdateHandler {
                    Task { @MainActor in
                        frameHandler(frame)
                    }
                }
                
                // Update stats
                let pqCount = await packetQueue.count
                let fbCount = await frameBuffer.count
                let drift = await (audioPlayer.hasBufferedAudio && audioPlayer.isPlaying) ? waitTime : 0.0
                
                let stats = PlayerDebugStats(
                    packetQueueCount: pqCount,
                    packetQueueMax: await packetQueue.maxSize,
                    frameBufferCount: fbCount,
                    frameBufferMax: await frameBuffer.maxSize,
                    avDrift: drift,
                    droppedFrameCount: droppedFrameCount,
                    isHardwareDecoded: isHardware,
                    decoderName: decoderName
                )
                
                if let handler = statsUpdateHandler {
                    await MainActor.run {
                        handler(stats)
                    }
                }
            }
        }
        
        // Loop exited naturally (not cancelled/stopped) and buffer is empty
        if !Task.isCancelled && reachedEndOfStream {
            print("[VideoDisplayLoop] End of stream reached (buffer empty/closed). Triggering completion.")
            if let handler = completionHandler {
                await MainActor.run {
                    handler()
                }
            }
        } else {
             print("[VideoDisplayLoop] Loop exited. Cancelled: \(Task.isCancelled), StreamEnd: \(reachedEndOfStream)")
        }
    }
}
