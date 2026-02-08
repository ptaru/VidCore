//
//  MediaPlayer+Debug.swift
//  VidCore
//

import Foundation

/// Real-time debug statistics for the video player
public struct PlayerDebugStats: Sendable {
  public var packetQueueCount: Int = 0
  public var packetQueueMax: Int = 0
  public var videoRendererReady: Bool = false
  public var audioBackend: String = "Unknown"
  public var lastVideoPTS: Double = 0
  public var decoderName: String = "Unknown"
  public var syncRate: Double = 0.0
}

extension MediaPlayer {
  func refreshDebugStats(videoPTS: Double? = nil) async {
    if let videoPTS = videoPTS {
      lastVideoPTS = videoPTS
    }

    let now = ProcessInfo.processInfo.systemUptime
    if now - lastStatsUpdateTime < 0.2 {
      return
    }
    lastStatsUpdateTime = now

    let queueCount = await packetQueue.count
    let queueMax = packetQueue.maxSize
    let videoReady = (renderer as? SampleBufferRenderer)?.isReadyForMoreMediaData ?? false
    let audioBackend: String = (audioOutput is SystemAudioRenderer) ? "System" : "AudioEngine"
    let syncRate = await playbackClock.rate
    let decoderName = decoder?.videoInfo.decoderName ?? "Unknown"

    debugStats.packetQueueCount = queueCount
    debugStats.packetQueueMax = queueMax
    debugStats.videoRendererReady = videoReady
    debugStats.audioBackend = audioBackend
    debugStats.lastVideoPTS = lastVideoPTS
    debugStats.syncRate = syncRate
    debugStats.decoderName = decoderName
  }
}
