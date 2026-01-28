//
//  AudioPlayer.swift
//  VidCore
//
//  Handles audio playback using AVAudioEngine
//
//  References:
//  - Decoupled architecture: Thread-safe time access via getMediaTime()
//

import Combine
import Foundation
import AVFoundation

/// Audio player for synchronized video playback using AVAudioEngine
@MainActor
public class AudioPlayer: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    private var audioFormat: AVAudioFormat?
    
    private var isEngineRunning = false
    private var sampleRate: Double = 48000.0
    private var playbackStartTime: AVAudioTime?
    
    // Thread-safe state container
    private final class AudioSyncState: @unchecked Sendable {
        private let lock = NSLock()
        private var _baseAudioPTS: Double = 0
        private var _totalSamplesEnqueued: Int64 = 0
        
        var baseAudioPTS: Double {
            get { lock.withLock { _baseAudioPTS } }
            set { lock.withLock { _baseAudioPTS = newValue } }
        }
        
        var totalSamplesEnqueued: Int64 {
            get { lock.withLock { _totalSamplesEnqueued } }
            set { lock.withLock { _totalSamplesEnqueued = newValue } }
        }
        
        func reset() {
            lock.withLock {
                _baseAudioPTS = 0
                _totalSamplesEnqueued = 0
            }
        }
    }
    
    private let syncState = AudioSyncState()
    
    public init() {
        setupEngine()
    }
    
    private func setupEngine() {
        engine.attach(playerNode)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)
        self.audioFormat = format
        
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
            isEngineRunning = true
        } catch {
            print("[AudioPlayer] Failed to start audio engine: \(error)")
        }
    }
    
    public func play() {
        if !isEngineRunning {
            try? engine.start()
            isEngineRunning = true
        }
        playerNode.play()
    }
    
    public func pause() {
        playerNode.pause()
        // Keep engine running to avoid state drift
    }
    
    /// Fully stops and clears audio playback.
    /// Use this for cleanup when the view model is being torn down.
    public func stop() {
        playerNode.stop()
        engine.stop()
        isEngineRunning = false
        resetSync()
    }
    
    /// Full cleanup - call when the player will not be reused.
    /// Detaches audio nodes from the engine graph to release memory.
    public func cleanup() {
        stop()
        engine.detach(playerNode)
    }

    public func seek(to seconds: Double) {
        playerNode.stop()
        resetSync()
        // Caller manages resume logic
    }

    public func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double) {
        if syncState.totalSamplesEnqueued == 0 {
            syncState.baseAudioPTS = pts
        }
        syncState.totalSamplesEnqueued += Int64(buffer.frameLength)
        
        if !isEngineRunning {
            try? engine.start()
            isEngineRunning = true
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    /// Reset sync state (call on seek)
    public func resetSync() {
        syncState.reset()
    }
    
    /// Whether audio buffers have been enqueued since last reset
    public nonisolated var hasBufferedAudio: Bool {
        syncState.totalSamplesEnqueued > 0
    }
    
    /// Current sample-based time (legacy)
    public var currentTime: TimeInterval {
        getMediaTime()
    }
    
    /// Actual media time accounting for base PTS - Safe to call from any thread
    public nonisolated func getMediaTime() -> Double {
        // AVAudioNode methods are thread-safe
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return syncState.baseAudioPTS
        }
        
        return syncState.baseAudioPTS + (Double(playerTime.sampleTime) / playerTime.sampleRate)
    }
    
    /// Actual media time accounting for base PTS
    public var mediaTime: Double {
        getMediaTime()
    }
    
    public nonisolated var isPlaying: Bool {
        return playerNode.isPlaying
    }
    
    public var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }
}
