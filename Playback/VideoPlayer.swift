//
//  VideoPlayer.swift
//  VidCore
//
//  High-level video player with playback orchestration
//

import Foundation
import Observation
import QuartzCore
import os

private let logger = Logger(subsystem: "com.vidcore", category: "player")

// Track deallocation for debugging memory issues
private let deallocationLogger = Logger(subsystem: "com.vidcore", category: "memory")

// MARK: - Timing Constants
private enum PlaybackTiming {
    static let displayLoopInterval: UInt64 = 8_000_000     // 8ms
    static let seekPauseDelay: UInt64 = 50_000_000         // 50ms
}

// MARK: - A/V Sync Constants
private enum SyncTiming {
    static let driftWarningThreshold: Double = 0.05        // 50ms - log warning
    static let driftCorrectionThreshold: Double = 0.15     // 150ms - take action
    static let severeDriftThreshold: Double = 1.0          // 1s - hard resync
    static let consecutiveDriftCountThreshold: Int = 3     // For normal correction
    static let severeDriftCountThreshold: Int = 5          // For hard resync
}

/// High-level video player that orchestrates decoding, rendering, and audio playback.
///
/// `VideoPlayer` provides a complete playback solution by managing the demux/decode/display
/// pipeline, A/V synchronization, seeking, and state management.
///
/// ## Example
/// ```swift
/// let player = VideoPlayer()
/// try await player.load(url: videoURL)
/// player.play()
/// ```
@Observable
@MainActor
public class VideoPlayer {
    // MARK: - Public State
    
    /// Current playback state
    public private(set) var state: PlaybackState = .idle
    
    /// Current playback time in seconds
    public private(set) var currentTime: Double = 0
    
    /// Total duration in seconds
    public private(set) var duration: Double = 0
    
    /// Video metadata (dimensions, frame rate, codec, etc.)
    public private(set) var videoInfo: VideoInfo?
    
    /// Current frame for rendering
    public private(set) var currentFrame: VideoFrame?
    
    /// Whether the video has an audio track
    public private(set) var hasAudio: Bool = false
    
    /// The rendering engine for displaying frames
    public let renderingEngine: RenderingEngine?
    
    // MARK: - Volume Control
    
    /// Playback volume (0.0 to 1.0)
    public var volume: Double = 1.0 {
        didSet { audioPlayer.volume = Float(volume) }
    }
    
    private var preMuteVolume: Double = 1.0
    
    /// Whether audio is muted
    public var isMuted: Bool {
        get { volume == 0 }
        set {
            if newValue {
                preMuteVolume = volume > 0 ? volume : 1.0
                volume = 0
            } else {
                volume = preMuteVolume
            }
        }
    }
    
    /// Toggle mute state
    public func toggleMute() {
        isMuted.toggle()
    }
    
    // MARK: - Internal Components
    
    private let audioPlayer = AudioPlayer()
    private var decoder: VideoDecoder?
    private let frameBuffer: VideoFrameBuffer
    private let packetQueue: PacketQueue
    
    // Task management
    nonisolated(unsafe) private var demuxTask: Task<Void, Never>?
    nonisolated(unsafe) private var decodeTask: Task<Void, Never>?
    nonisolated(unsafe) private var displayTask: Task<Void, Never>?
    nonisolated(unsafe) private var currentSeekTask: Task<Void, Never>?
    
    // Timing state
    private var playbackStartTime: CFTimeInterval = 0
    private var pauseTimestamp: CFTimeInterval = 0
    private var firstFramePTS: Double = 0
    private var audioStartOffset: Double = 0
    
    // A/V sync tracking
    private var consecutiveDriftCount: Int = 0
    
    // MARK: - Initialization
    
    /// Creates a new video player.
    ///
    /// - Parameters:
    ///   - frameBufferSize: Maximum frames to buffer (default: 3)
    ///   - packetQueueSize: Maximum packets to queue (default: 15)
    public init(frameBufferSize: Int = 3, packetQueueSize: Int = 15) {
        self.renderingEngine = RenderingEngine()
        self.frameBuffer = VideoFrameBuffer(maxSize: frameBufferSize)
        self.packetQueue = PacketQueue(maxSize: packetQueueSize)
    }
    
    // MARK: - Public API
    
    /// Load a video file for playback.
    ///
    /// - Parameter url: The file URL of the video to load.
    /// - Throws: `VideoPlayerError` if the file cannot be loaded.
    public func load(url: URL) async throws {
        state = .loading
        logger.info("[VideoPlayer] Loading video: \(url.lastPathComponent)")
        
        do {
            decoder = try VideoDecoder(url: url)
            if let decoder = decoder {
                duration = decoder.videoInfo.duration
                videoInfo = decoder.videoInfo
                logger.info("[VideoPlayer] Video loaded: \(decoder.videoInfo.width)x\(decoder.videoInfo.height), duration: \(self.duration)s")
                
                // Decode first frame for preview using unified pipeline
                while !Task.isCancelled {
                    guard let packet = await decoder.demuxNextPacket() else { break }
                    let frames = await decoder.decodePacket(packet)
                    if let videoFrame = frames.compactMap({ frame -> VideoFrame? in
                        if case .video(let vf) = frame { return vf }
                        return nil
                    }).first {
                        currentFrame = videoFrame
                        break
                    }
                }
            }
            state = .ready
        } catch {
            logger.error("[VideoPlayer] Failed to load video: \(error.localizedDescription)")
            state = .error(.decoderInitFailed(error.localizedDescription))
            throw VideoPlayerError.decoderInitFailed(error.localizedDescription)
        }
    }
    
    /// Whether the player is currently playing.
    public var isPlaying: Bool {
        state == .playing
    }
    
    /// Start or resume playback.
    public func play() {
        guard state == .ready || state == .paused || state == .finished else { return }
        
        // Reset if finished - seek to beginning and restart playback
        // We need to start fresh loops since the old ones have terminated
        if state == .finished {
            Task {
                await seek(to: 0)
                // After seek, buffers are suspended and loops have terminated.
                // Resume buffers and set to .ready so play() starts fresh loops.
                await packetQueue.resume()
                await frameBuffer.resume()
                state = .ready
                play()
            }
            return
        }
        
        // Resume from paused state
        if state == .paused {
            state = .playing
            audioPlayer.play()
            
            // Adjust timing to account for pause duration
            let pauseDuration = CACurrentMediaTime() - pauseTimestamp
            playbackStartTime += pauseDuration
            
            // Resume buffers - loops will continue
            Task {
                await packetQueue.resume()
                await frameBuffer.resume()
            }
            
            logger.debug("[VideoPlayer] Playback resumed")
            return
        }
        
        // Start fresh from ready state
        state = .playing
        audioPlayer.play()
        
        // Start parallel demux/decode/display pipeline
        demuxTask = Task { [weak self] in
            await self?.runDemuxLoop()
        }
        
        decodeTask = Task { [weak self] in
            await self?.runDecodeLoop()
        }
        
        displayTask = Task { [weak self] in
            await self?.runDisplayLoop()
        }
        
        logger.debug("[VideoPlayer] Playback started")
    }
    
    /// Pause playback.
    public func pause() {
        guard state == .playing else { return }
        
        state = .paused
        pauseTimestamp = CACurrentMediaTime()
        audioPlayer.pause()
        
        // Suspend buffers - loops will yield when they check suspension state
        Task {
            await packetQueue.suspend()
            await frameBuffer.suspend()
        }
        
        logger.debug("[VideoPlayer] Playback paused at \(self.currentTime)s")
    }
    
    /// Toggle between play and pause.
    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    /// Seek to a specific time.
    ///
    /// - Parameters:
    ///   - seconds: Target time in seconds.
    ///   - accurate: If true, seeks to exact frame; if false, seeks to nearest keyframe.
    public func seek(to seconds: Double, accurate: Bool = true) async {
        currentSeekTask?.cancel()
        
        let task = Task { @MainActor [weak self] in
            guard let self = self, let decoder = decoder else { return }
            guard !Task.isCancelled else { return }
            
            let clampedSeconds = max(0, min(seconds, duration))
            let wasPlaying = state == .playing
            let previousState = state
            
            // Enter seeking state to prevent race conditions
            state = .seeking
            audioPlayer.pause()
            
            // Suspend loops first
            await packetQueue.suspend()
            await frameBuffer.suspend()
            
            guard !Task.isCancelled else {
                // Restore previous state if cancelled
                state = previousState
                if wasPlaying {
                    audioPlayer.play()
                    await packetQueue.resume()
                    await frameBuffer.resume()
                }
                return
            }
            
            // Reset buffers to clear stale data
            await packetQueue.reset()
            await frameBuffer.reset()
            
            do {
                try await decoder.seek(to: clampedSeconds, accurate: accurate)
                
                audioPlayer.seek(to: clampedSeconds)
                
                playbackStartTime = CACurrentMediaTime() - clampedSeconds
                firstFramePTS = clampedSeconds
                audioStartOffset = clampedSeconds
                currentTime = clampedSeconds
                
                if wasPlaying {
                    // Resume playback - buffers are already reset and ready
                    state = .playing
                    audioPlayer.play()
                    await packetQueue.resume()
                    await frameBuffer.resume()
                } else {
                    // Decode one frame to show at seek position
                    while !Task.isCancelled {
                        guard let packet = await decoder.demuxNextPacket() else { break }
                        let frames = await decoder.decodePacket(packet)
                        if let videoFrame = frames.compactMap({ frame -> VideoFrame? in
                            if case .video(let vf) = frame { return vf }
                            return nil
                        }).first {
                            await frameBuffer.push(videoFrame)
                            currentFrame = videoFrame
                            break
                        }
                    }
                    // Re-suspend buffers to prevent loops from running while paused
                    await packetQueue.suspend()
                    await frameBuffer.suspend()
                    state = .paused
                }
                
                logger.debug("[VideoPlayer] Seeked to \(clampedSeconds)s (accurate: \(accurate))")
            } catch {
                logger.error("[VideoPlayer] Seek failed: \(error.localizedDescription)")
                // Restore to paused state on error
                state = .paused
            }
        }
        
        currentSeekTask = task
        await task.value
    }
    
    /// Close the player and release resources.
    public func close() async {
        logger.debug("[VideoPlayer] Closing VideoPlayer")
        
        if isPlaying {
            pause()
        }
        
        audioPlayer.cleanup()  // Full cleanup with node detachment
        
        demuxTask?.cancel()
        decodeTask?.cancel()
        displayTask?.cancel()
        currentSeekTask?.cancel()
        
        await demuxTask?.value
        await decodeTask?.value
        await displayTask?.value
        
        demuxTask = nil
        decodeTask = nil
        displayTask = nil
        currentSeekTask = nil
        
        await packetQueue.reset()
        await frameBuffer.reset()
        
        decoder?.close()
        decoder = nil
        
        currentFrame = nil
        
        // Flush Metal texture cache to release GPU resources
        renderingEngine?.flush()
        
        state = .idle
        
        logger.info("[VideoPlayer] Closed")
    }
    
    // MARK: - Demux Loop
    
    private func runDemuxLoop() async {
        guard let decoder = decoder else { return }
        
        logger.debug("[VideoPlayer] Demux loop started")
        
        while !Task.isCancelled {
            // Check if queue is suspended and wait
            if await packetQueue.suspended {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            
            guard let packet = await decoder.demuxNextPacket() else {
                await packetQueue.close()
                logger.debug("[VideoPlayer] Demux reached end of stream")
                break
            }
            
            await packetQueue.push(packet)
        }
        
        logger.debug("[VideoPlayer] Demux loop ended")
    }
    
    // MARK: - Decode Loop
    
    private func runDecodeLoop() async {
        guard let decoder = decoder else { return }
        
        logger.debug("[VideoPlayer] Decode loop started")
        
        while !Task.isCancelled {
            // Check if queue is suspended and wait
            if await packetQueue.suspended {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            
            guard let packet = await packetQueue.pop() else {
                // nil could mean suspended or end of stream - check suspension
                if await packetQueue.suspended {
                    continue
                }
                
                // Flush and drain decoder
                logger.debug("[VideoPlayer] Decode reached end of packets, flushing decoder")
                
                await decoder.flushVideoDecoder()
                
                var drainedCount = 0
                while !Task.isCancelled {
                    guard let frame = await decoder.drainVideoFrame() else {
                        break
                    }
                    await frameBuffer.pushWithBackpressure(frame)
                    drainedCount += 1
                }
                logger.debug("[VideoPlayer] Drained \(drainedCount) remaining frames from decoder")
                
                await frameBuffer.close()
                break
            }
            
            guard !Task.isCancelled else { break }
            
            let decodedFrames = await decoder.decodePacket(packet)
            for frame in decodedFrames {
                switch frame {
                case .video(let videoFrame):
                    await frameBuffer.pushWithBackpressure(videoFrame)
                case .audio(let buffer, let pts):
                    await MainActor.run {
                        hasAudio = true
                        audioPlayer.enqueue(buffer, pts: pts)
                    }
                }
            }
        }
        
        logger.debug("[VideoPlayer] Decode loop ended")
    }
    
    // MARK: - Display Loop
    
    private func runDisplayLoop() async {
        var hasStarted = false
        
        logger.debug("[VideoPlayer] Display loop started")
        
        while !Task.isCancelled {
            // Check if buffer is suspended and wait
            if await frameBuffer.suspended {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            
            let frameAvailable = await frameBuffer.waitForFrameAvailable()
            
            guard frameAvailable else {
                // nil/false could mean suspended or end of stream - check suspension
                if await frameBuffer.suspended {
                    continue
                }
                
                if !Task.isCancelled && state == .playing {
                    await MainActor.run {
                        state = .finished
                        logger.info("[VideoPlayer] Playback finished")
                    }
                }
                break
            }
            
            guard let nextFrame = await frameBuffer.peek() else {
                continue
            }
            
            if !hasStarted {
                playbackStartTime = CACurrentMediaTime()
                firstFramePTS = nextFrame.presentationTime
                audioStartOffset = nextFrame.presentationTime
                hasStarted = true
            }
            
            // Calculate current playback time (audio is master clock when available)
            // Only update currentTime when actually playing to avoid race with seek
            let currentPlaybackTime: Double
            if hasAudio && audioPlayer.isPlaying {
                currentPlaybackTime = audioPlayer.mediaTime
            } else {
                currentPlaybackTime = (CACurrentMediaTime() - playbackStartTime) + firstFramePTS
            }
            
            if state == .playing {
                currentTime = currentPlaybackTime
            }
            
            // Calculate wait time
            let waitTime = nextFrame.presentationTime - currentPlaybackTime
            
            // A/V sync drift detection (only when using audio clock)
            if hasAudio && audioPlayer.isPlaying {
                let drift = waitTime  // positive = video ahead, negative = video behind
                
                if abs(drift) > SyncTiming.driftWarningThreshold {
                    consecutiveDriftCount += 1
                    
                    // Severe drift - hard resync by seeking video to audio position
                    if abs(drift) > SyncTiming.severeDriftThreshold 
                        && consecutiveDriftCount >= SyncTiming.severeDriftCountThreshold {
                        
                        logger.warning("[VideoPlayer] Severe A/V drift (\(Int(abs(drift) * 1000))ms) - triggering hard resync")
                        consecutiveDriftCount = 0
                        
                        // Seek video to current audio position
                        let audioPosition = audioPlayer.mediaTime
                        await packetQueue.reset()
                        await frameBuffer.reset()
                        
                        if let decoder = decoder {
                            try? await decoder.seek(to: audioPosition, accurate: true)
                            playbackStartTime = CACurrentMediaTime() - audioPosition
                            firstFramePTS = audioPosition
                        }
                        continue
                    }
                    
                    // Normal drift handling
                    if abs(drift) > SyncTiming.driftCorrectionThreshold 
                        && consecutiveDriftCount >= SyncTiming.consecutiveDriftCountThreshold {
                        
                        if drift > 0 {
                            // Video ahead of audio - let the wait logic below handle it naturally
                            logger.debug("[VideoPlayer] A/V sync: video ahead by \(Int(drift * 1000))ms, waiting for audio")
                        } else {
                            // Video behind audio - late frame drop logic below handles this
                            logger.debug("[VideoPlayer] A/V sync: video behind by \(Int(-drift * 1000))ms, will drop late frames")
                        }
                    }
                } else {
                    consecutiveDriftCount = 0
                }
            }
            
            if waitTime > 0.1 {
                try? await Task.sleep(nanoseconds: PlaybackTiming.displayLoopInterval)
                continue
            } else if waitTime > 0 {
                let waitNanos = UInt64(waitTime * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNanos)
            } else {
                let frameDuration = 1.0 / (videoInfo?.frameRate ?? 30.0)
                if waitTime < -frameDuration {
                    _ = await frameBuffer.pop()
                    logger.debug("[VideoPlayer] Dropped late frame: \(Int(waitTime * -1000))ms behind")
                    continue
                }
            }
            
            if let frame = await frameBuffer.pop() {
                currentFrame = frame
            }
        }
        
        logger.debug("[VideoPlayer] Display loop ended")
    }
    
    // MARK: - Cleanup
    
    /// Synchronously cancel all background tasks.
    /// Call this for cleanup when async close() cannot be awaited (e.g., in deinit).
    public nonisolated func cancelAllTasks() {
        demuxTask?.cancel()
        decodeTask?.cancel()
        displayTask?.cancel()
        currentSeekTask?.cancel()
    }
    
    /// Synchronous close for use from deinit or when async cannot be awaited.
    /// Releases heavy resources (decoder, audio engine, renderer cache) immediately.
    /// Tasks are cancelled but not awaited - they will terminate naturally.
    public nonisolated func closeSync() {
        deallocationLogger.info("[VideoPlayer] closeSync() - releasing resources")

        // Cancel all running tasks
        cancelAllTasks()

        // Synchronously access MainActor-isolated properties for cleanup
        // This is safe in deinit as we're the last reference holder
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                // Pause playback first
                if isPlaying {
                    pause()
                }

                audioPlayer.cleanup()

                // Release decoder and its pools FIRST (this releases the CVPixelBufferPools)
                decoder?.close()
                decoder = nil

                // Release current frame reference
                currentFrame = nil

                // Clear task references
                demuxTask = nil
                decodeTask = nil
                displayTask = nil
                currentSeekTask = nil

                // Flush Metal texture cache
                renderingEngine?.flush()

                // Reset state
                state = .idle

                // CRITICAL: Reset buffers to release CVPixelBuffer references
                // Capture actor references and reset asynchronously
                let pq = packetQueue
                let fb = frameBuffer
                Task.detached(priority: .high) {
                    await pq.reset()
                    await fb.reset()
                    deallocationLogger.info("[VideoPlayer] Buffers reset completed")
                }
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    // Pause playback first
                    if isPlaying {
                        pause()
                    }

                    audioPlayer.cleanup()

                    // Release decoder and its pools FIRST (this releases the CVPixelBufferPools)
                    decoder?.close()
                    decoder = nil

                    // Release current frame reference
                    currentFrame = nil

                    // Clear task references
                    demuxTask = nil
                    decodeTask = nil
                    displayTask = nil
                    currentSeekTask = nil

                    // Flush Metal texture cache
                    renderingEngine?.flush()

                    // Reset state
                    state = .idle

                    // CRITICAL: Reset buffers to release CVPixelBuffer references
                    // Capture actor references and reset asynchronously
                    let pq = packetQueue
                    let fb = frameBuffer
                    Task.detached(priority: .high) {
                        await pq.reset()
                        await fb.reset()
                        deallocationLogger.info("[VideoPlayer] Buffers reset completed")
                    }
                }
            }
        }

        deallocationLogger.info("[VideoPlayer] closeSync() completed")
    }
    
    nonisolated deinit {
        deallocationLogger.info("[VideoPlayer] DEINIT - deallocating")
        // Only cancel tasks here - closeSync() was already called by ViewModel.cleanupSync()
        // This is a fallback for edge cases where VideoPlayer is deallocated without explicit cleanup
        cancelAllTasks()
    }
}
