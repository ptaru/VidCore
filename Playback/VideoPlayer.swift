//
//  VideoPlayer.swift
//  VidCore
//
//  High-level video player with playback orchestration
//
//  Decoupled Architecture:
//  - VideoPlayer (MainActor): Orchestrates high-level state, user input, and UI/Debug mirroring.
//  - VideoDisplayLoop (Actor): Runs the display loop on a background thread, pushing frames to renderer.
//

import Foundation
import Observation
import QuartzCore

// MARK: - Timing Constants
private enum PlaybackTiming {
    static let seekPauseDelay: UInt64 = 50_000_000         // 50ms
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
    
    /// Current frame for rendering (Mirrored from Display Loop for Debug/UI)
    /// Note: This is NOT the source of truth for the screen.
    public private(set) var currentFrame: VideoFrame?
    
    /// Whether the video has an audio track
    public private(set) var hasAudio: Bool = false
    
    /// Real-time debug statistics
    public private(set) var debugStats = PlayerDebugStats()

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
    
    // Decoupled Display Loop
    private let displayLoop: VideoDisplayLoop
    
    // Task management
    nonisolated(unsafe) private var demuxTask: Task<Void, Never>?
    nonisolated(unsafe) private var decodeTask: Task<Void, Never>?
    nonisolated(unsafe) private var currentSeekTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    /// Creates a new video player.
    ///
    /// - Parameters:
    ///   - frameBufferSize: Maximum frames to buffer (default: 3)
    ///   - packetQueueSize: Maximum packets to queue (default: 15)
    public init(frameBufferSize: Int = 3, packetQueueSize: Int = 15) {

        self.frameBuffer = VideoFrameBuffer(maxSize: frameBufferSize)
        self.packetQueue = PacketQueue(maxSize: packetQueueSize)
        self.displayLoop = VideoDisplayLoop(frameBuffer: frameBuffer, packetQueue: packetQueue, audioPlayer: audioPlayer)
        
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        Task {
            await displayLoop.setStatsHandler { [weak self] stats in
                self?.debugStats = stats
            }
            await displayLoop.setFrameUpdateHandler { [weak self] frame in
                self?.currentFrame = frame // Update mirror
                self?.currentTime = frame.presentationTime
            }
            await displayLoop.setCompletionHandler { [weak self] in
                guard let self = self else { return }
                if self.state == .playing {
                    self.state = .finished
                    // Ensure audio is paused so it doesn't try to continue or hold resources
                    self.audioPlayer.pause()
                }
            }
        }
    }
    
    // MARK: - Public API
    
    /// Sets the target renderer for video frames.
    /// This connects the decoupled display loop to the screen.
    public func setRenderer(_ target: VideoRendererTarget?) async {
        await displayLoop.setRenderer(target)
    }
    
    /// Load a video file for playback.
    ///
    /// - Parameter url: The file URL of the video to load.
    /// - Throws: `VideoPlayerError` if the file cannot be loaded.
    public func load(url: URL) async throws {
        state = .loading
        
        do {
            decoder = try VideoDecoder(url: url)
            if let decoder = decoder {

                duration = decoder.videoInfo.duration
                videoInfo = decoder.videoInfo
                
                await displayLoop.setVideoInfo(decoder.videoInfo)

                while !Task.isCancelled {
                    guard let packet = await decoder.demuxNextPacket() else { break }
                    let frames = await decoder.decodePacket(packet)
                    if let videoFrame = frames.compactMap({ frame -> VideoFrame? in
                        if case .video(let vf) = frame { return vf }
                        return nil
                    }).first {
                        currentFrame = videoFrame
                        // Push initial frame to buffer so loop picks it up immediately
                        await frameBuffer.push(videoFrame)
                        break
                    }
                }
            }
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
            print("[VideoPlayer] Play called in .finished state. Restarting...")
            Task {
                await seek(to: 0)
                await packetQueue.resume()
                await frameBuffer.resume()
                state = .ready
                print("[VideoPlayer] State unset to .ready, calling play()")
                play()
            }
            return
        }
        

        if state == .paused {
            print("[VideoPlayer] Play called in .paused state. Resuming...")
            state = .playing
            audioPlayer.play()
            Task {
                await displayLoop.start()
            }
            
            Task {
                await packetQueue.resume()
                await frameBuffer.resume()
            }

            startTasks()
            return
        }
        
        print("[VideoPlayer] Play called. Starting from fresh.")
        state = .playing
        audioPlayer.play()
        Task {
            await displayLoop.start()
        }
        
        startTasks()
    }
    
    /// Pause playback.
    public func pause() {
        guard state == .playing else { return }
        
        state = .paused
        audioPlayer.pause()
        Task {
            await displayLoop.pause()
        }
        
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
            
            await displayLoop.pause()
            await packetQueue.suspend()
            await frameBuffer.suspend()
            
            guard !Task.isCancelled else {
                // Restore previous state if cancelled
                state = previousState
                if wasPlaying {
                    audioPlayer.play()
                    await displayLoop.start()
                    await packetQueue.resume()
                    await frameBuffer.resume()
                }
                return
            }
            
            await packetQueue.reset()
            await frameBuffer.reset()
            await displayLoop.reset() // Ensure loop state is clean
            
            do {
                if let seekFrame = try await decoder.seek(to: clampedSeconds, accurate: accurate) {
                    currentFrame = seekFrame
                    // Force display the frame immediately since loop might be paused
                    await displayLoop.displayFrame(seekFrame)
                    
                    // Push the seek frame to buffer so it flows into the display loop when playing
                    await frameBuffer.push(seekFrame)
                    
                    // Update timing to match the actual frame found
                    currentTime = seekFrame.presentationTime
                } else {
                    // Fallback if no frame returned (should catch in error)
                    currentTime = clampedSeconds
                }
                
                audioPlayer.seek(to: currentTime)
                
                guard !Task.isCancelled else {
                    return 
                }
                
                // 2. Restart tasks now that seek is complete and queues are clean
                self.startTasks()
                
                if wasPlaying {
                    state = .playing
                    audioPlayer.play()
                    await displayLoop.start()
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
        await displayLoop.stop()
        
        currentSeekTask?.cancel()
        currentSeekTask = nil
        
        await packetQueue.reset()
        await frameBuffer.reset()
        
        decoder?.close()
        decoder = nil
        
        currentFrame = nil
        
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
    }
    
    private func stopTasks() async {
        demuxTask?.cancel()
        decodeTask?.cancel()
        // Display loop is controlled separately
        
        await demuxTask?.value
        await decodeTask?.value
        
        demuxTask = nil
        decodeTask = nil
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
    
    // MARK: - Cleanup
    
    /// Synchronously cancel all background tasks.
    public nonisolated func cancelAllTasks() {
        demuxTask?.cancel()
        decodeTask?.cancel()
        currentSeekTask?.cancel()
    }
    
    /// Synchronous close for use from deinit or when async cannot be awaited.
    public nonisolated func closeSync() {
        cancelAllTasks()

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if isPlaying {
                    pause()
                }

                audioPlayer.cleanup()
                decoder?.close()
                decoder = nil
                currentFrame = nil
                
                Task {
                    await displayLoop.stop()
                }

                demuxTask = nil
                decodeTask = nil
                currentSeekTask = nil

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
                    
                    Task {
                        await displayLoop.stop()
                    }

                    demuxTask = nil
                    decodeTask = nil
                    currentSeekTask = nil

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

/// Real-time debug statistics for the video player
public struct PlayerDebugStats: Sendable {
    public var packetQueueCount: Int = 0
    public var packetQueueMax: Int = 0
    public var frameBufferCount: Int = 0
    public var frameBufferMax: Int = 0
    public var avDrift: Double = 0.0
    public var droppedFrameCount: Int = 0
    public var isHardwareDecoded: Bool = false
    public var decoderName: String = "Unknown"
}
