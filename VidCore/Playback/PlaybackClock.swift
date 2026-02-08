//
//  PlaybackClock.swift
//  VidCore
//
//  Shared AVSampleBufferRenderSynchronizer for system scheduling (video + audio renderers)
//

import AVFoundation
import CoreMedia
import Foundation

/// Owns a system synchronizer to drive AVSampleBuffer renderers (video + audio).
public actor PlaybackClock {
  private let synchronizer: AVSampleBufferRenderSynchronizer
  private weak var currentVideoRenderer: AVQueuedSampleBufferRendering?

  /// Creates a new playback clock.
  /// - Parameter audioRenderer: The audio renderer to synchronize with, or nil if no audio.
  public init(audioRenderer: AVSampleBufferAudioRenderer?) {
    self.synchronizer = AVSampleBufferRenderSynchronizer()
    if let audioRenderer {
      synchronizer.addRenderer(audioRenderer)
    }
    synchronizer.setRate(0.0, time: .zero)
  }

  /// Starts playback at the specified rate.
  /// - Parameter rate: The playback rate (1.0 for normal speed).
  public func play(rate: Double = 1.0) {
    synchronizer.setRate(Float(rate), time: .invalid)
  }

  /// Pauses playback.
  public func pause() {
    synchronizer.setRate(0.0, time: .invalid)
  }

  /// Sets the playback rate without changing the current time.
  /// - Parameter rate: The new playback rate.
  public func setRate(_ rate: Double) {
    synchronizer.setRate(Float(rate), time: .invalid)
  }

  /// Seeks to a specific time.
  /// - Parameter seconds: The target time in seconds.
  public func seek(to seconds: Double) {
    let time = CMTime(seconds: seconds, preferredTimescale: 60000)
    synchronizer.setRate(0.0, time: time)
  }

  /// Sets the current playback time while maintaining the current rate.
  /// - Parameter seconds: The target time in seconds.
  public func setTime(_ seconds: Double) {
    let time = CMTime(seconds: seconds, preferredTimescale: 60000)
    synchronizer.setRate(synchronizer.rate, time: time)
  }

  /// Returns the current playback time in seconds.
  public func getCurrentTime() -> Double {
    synchronizer.currentTime().seconds
  }

  /// The current playback rate.
  public var rate: Double {
    Double(synchronizer.rate)
  }

  /// Attaches or detaches a video renderer to the shared synchronizer.
  /// - Parameter renderer: The renderer to attach, or nil to detach.
  public func attachVideoRenderer(_ renderer: AVQueuedSampleBufferRendering?) {
    if let current = currentVideoRenderer {
      synchronizer.removeRenderer(current, at: .zero)
      currentVideoRenderer = nil
    }

    guard let renderer else { return }
    synchronizer.addRenderer(renderer)
    currentVideoRenderer = renderer
  }
}
