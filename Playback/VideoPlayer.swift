//
//  VideoPlayer.swift
//  VidCore
//
//  High-level video player with playback orchestration
//

import Foundation
import Observation
import QuartzCore



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
        state = .loading

        
        do {
            decoder = try VideoDecoder(url: url)
            if let decoder = decoder {
                duration = decoder.videoInfo.duration
                videoInfo = decoder.videoInfo
                duration = decoder.videoInfo.duration
                videoInfo = decoder.videoInfo

                

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
            state = .ready
        } catch {

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
        

        if state == .finished {
            Task {
                await seek(to: 0)
                await packetQueue.resume()
                await frameBuffer.resume()
                state = .ready
                play()
            }
            return
        }
        

        if state == .paused {
            state = .playing
            audioPlayer.play()
            
            let pauseDuration = CACurrentMediaTime() - pauseTimestamp
            playbackStartTime += pauseDuration
            
            Task {
                await packetQueue.resume()
                await frameBuffer.resume()
            }

            startTasks()
            return
        }
        
        state = .playing
        audioPlayer.play()
        

        startTasks()
        

    }
    
    /// Pause playback.
    public func pause() {
        guard state == .playing else { return }
        
        state = .paused
        pauseTimestamp = CACurrentMediaTime()
        audioPlayer.pause()
        

        Task {
            await packetQueue.suspend()
            await frameBuffer.suspend()
        }
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
            
            // 1. Stop background tasks to prevent resource contention and race conditions
            await self.stopTasks()
            
            guard !Task.isCancelled else { return }
            
            let clampedSeconds = max(0, min(seconds, duration))
            let wasPlaying = state == .playing
            let previousState = state
            
            // Enter seeking state to prevent race conditions
            state = .seeking
            audioPlayer.pause()
            

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
            

            await packetQueue.reset()
            await frameBuffer.reset()
            
            do {
                if let seekFrame = try await decoder.seek(to: clampedSeconds, accurate: accurate) {
                    currentFrame = seekFrame
                    // Push the seek frame to buffer so it flows into the display loop when playing
                    await frameBuffer.push(seekFrame)
                    
                    // Update timing to match the actual frame found
                    currentTime = seekFrame.presentationTime
                    firstFramePTS = seekFrame.presentationTime
                    audioStartOffset = seekFrame.presentationTime
                } else {
                    // Fallback if no frame returned (should catch in error)
                    currentTime = clampedSeconds
                    firstFramePTS = clampedSeconds
                    audioStartOffset = clampedSeconds
                }
                
                audioPlayer.seek(to: currentTime)
                playbackStartTime = CACurrentMediaTime() - currentTime
                
                guard !Task.isCancelled else {
                    return 
                }
                
                // 2. Restart tasks now that seek is complete and queues are clean
                self.startTasks()
                
                if wasPlaying {
                    state = .playing
                    audioPlayer.play()
                    await packetQueue.resume()
                    await frameBuffer.resume()
                } else {
                    // We already have the frame displayed, so just pause
                    await packetQueue.suspend()
                    await frameBuffer.suspend()
                    state = .paused
                }
            } catch {

                // Restore to paused state on error
                state = .paused
            }
        }
        
        currentSeekTask = task
        await task.value
    }
    
    /// Close the player and release resources.
    public func close() async {

        
        if isPlaying {
            pause()
        }
        
        audioPlayer.cleanup()
        
        await stopTasks()
        currentSeekTask?.cancel()
        currentSeekTask = nil
        
        await packetQueue.reset()
        await frameBuffer.reset()
        
        decoder?.close()
        decoder = nil
        
        currentFrame = nil
        
        // Flush Metal texture cache to release GPU resources
        renderingEngine?.flush()
        
        state = .idle
        
        state = .idle
        

    }
    
    // MARK: - Task Management
    
    private func startTasks() {
        // Only start if not already running
        if demuxTask == nil {
            demuxTask = Task { [weak self] in
                await self?.runDemuxLoop()
            }
        }
        
        if decodeTask == nil {
            decodeTask = Task { [weak self] in
                await self?.runDecodeLoop()
            }
        }
        
        if displayTask == nil {
            displayTask = Task { [weak self] in
                await self?.runDisplayLoop()
            }
        }
    }
    
    private func stopTasks() async {
        demuxTask?.cancel()
        decodeTask?.cancel()
        displayTask?.cancel()
        
        await demuxTask?.value
        await decodeTask?.value
        await displayTask?.value
        
        demuxTask = nil
        decodeTask = nil
        displayTask = nil
    }
    
    // MARK: - Demux Loop
    
    private func runDemuxLoop() async {
        guard let decoder = decoder else { return }

        while !Task.isCancelled {
            if await packetQueue.suspended {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            
            guard let packet = await decoder.demuxNextPacket() else {
                await packetQueue.close()
                break
            }
            
            await packetQueue.push(packet)
        }
    }
    
    // MARK: - Decode Loop
    
    private func runDecodeLoop() async {
        guard let decoder = decoder else { return }
        
        while !Task.isCancelled {
            if await packetQueue.suspended {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            
            guard let packet = await packetQueue.pop() else {
                if await packetQueue.suspended {
                    continue
                }
                

                
                await decoder.flushVideoDecoder()
                
                var drainedCount = 0
                while !Task.isCancelled {
                    guard let frame = await decoder.drainVideoFrame() else {
                        break
                    }
                    await frameBuffer.pushWithBackpressure(frame)
                    drainedCount += 1
                }

                
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
    }
    
    // MARK: - Display Loop
    
    private func runDisplayLoop() async {
        var hasStarted = false
        
        while !Task.isCancelled {
            if await frameBuffer.suspended {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                continue
            }
            
            let frameAvailable = await frameBuffer.waitForFrameAvailable()
            
            guard frameAvailable else {
                if await frameBuffer.suspended {
                    continue
                }
                
                if !Task.isCancelled && state == .playing {
                    await MainActor.run {
                        state = .finished

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
            
            // Audio is master clock when available and stable; fall back to video clock during audio re-sync
            let currentPlaybackTime: Double
            if hasAudio && audioPlayer.isPlaying && audioPlayer.hasBufferedAudio {
                currentPlaybackTime = audioPlayer.mediaTime
            } else {
                currentPlaybackTime = (CACurrentMediaTime() - playbackStartTime) + firstFramePTS
            }
            
            if state == .playing {
                currentTime = currentPlaybackTime
            }
            
            let waitTime = nextFrame.presentationTime - currentPlaybackTime
            
            if hasAudio && audioPlayer.isPlaying {
                let drift = waitTime
                
                if abs(drift) > SyncTiming.driftWarningThreshold {
                    consecutiveDriftCount += 1
                    
                    if abs(drift) > SyncTiming.severeDriftThreshold 
                        && consecutiveDriftCount >= SyncTiming.severeDriftCountThreshold {
                        

                        consecutiveDriftCount = 0
                        
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
                    
                    if abs(drift) > SyncTiming.driftCorrectionThreshold 
                        && consecutiveDriftCount >= SyncTiming.consecutiveDriftCountThreshold {
                        
                    if abs(drift) > SyncTiming.driftCorrectionThreshold 
                        && consecutiveDriftCount >= SyncTiming.consecutiveDriftCountThreshold {
                        
                        if drift > 0 {

                        } else {

                        }
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

                    continue
                }
            }
            
            if let frame = await frameBuffer.pop() {
                currentFrame = frame
            }
        }
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


        // Cancel all running tasks
        cancelAllTasks()

        // Synchronously access MainActor-isolated properties for cleanup
        // This is safe in deinit as we're the last reference holder
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if isPlaying {
                    pause()
                }

                audioPlayer.cleanup()

                decoder?.close()
                decoder = nil

                currentFrame = nil

                demuxTask = nil
                decodeTask = nil
                displayTask = nil
                currentSeekTask = nil

                renderingEngine?.flush()
                state = .idle

                let pq = packetQueue
                let fb = frameBuffer
                Task.detached(priority: .high) {
                    await pq.reset()
                    await fb.reset()
                }
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    if isPlaying {
                        pause()
                    }

                    audioPlayer.cleanup()

                    decoder?.close()
                    decoder = nil

                    currentFrame = nil

                    demuxTask = nil
                    decodeTask = nil
                    displayTask = nil
                    currentSeekTask = nil

                    renderingEngine?.flush()

                    state = .idle

                    let pq = packetQueue
                    let fb = frameBuffer
                    Task.detached(priority: .high) {
                        await pq.reset()
                        await fb.reset()

                    }
                }
            }
        }


    }
    
    nonisolated deinit {


        cancelAllTasks()
    }
}
