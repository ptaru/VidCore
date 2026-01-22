//
//  AudioPlayer.swift
//  VidCore
//
//  Handles audio playback using AVAudioEngine
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
    
    private var baseAudioPTS: Double = 0
    private var totalSamplesEnqueued: Int64 = 0
    
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
        if totalSamplesEnqueued == 0 {
            baseAudioPTS = pts
        }
        totalSamplesEnqueued += Int64(buffer.frameLength)
        
        if !isEngineRunning {
            try? engine.start()
            isEngineRunning = true
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    /// Reset sync state (call on seek)
    public func resetSync() {
        baseAudioPTS = 0
        totalSamplesEnqueued = 0
    }
    
    /// Whether audio buffers have been enqueued since last reset
    public var hasBufferedAudio: Bool {
        totalSamplesEnqueued > 0
    }
    
    /// Current sample-based time (legacy)
    public var currentTime: TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
    
    /// Actual media time accounting for base PTS
    public var mediaTime: Double {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return baseAudioPTS
        }
        return baseAudioPTS + (Double(playerTime.sampleTime) / playerTime.sampleRate)
    }
    
    public var isPlaying: Bool {
        return playerNode.isPlaying
    }
    
    public var volume: Float {
        get { playerNode.volume }
        set { playerNode.volume = newValue }
    }
}
