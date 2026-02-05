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

  public init(audioRenderer: AVSampleBufferAudioRenderer?) {
    self.synchronizer = AVSampleBufferRenderSynchronizer()
    if let audioRenderer {
      synchronizer.addRenderer(audioRenderer)
    }
    synchronizer.setRate(0.0, time: .zero)
  }

  public func play(rate: Double = 1.0) {
    synchronizer.setRate(Float(rate), time: .invalid)
  }

  public func pause() {
    synchronizer.setRate(0.0, time: .invalid)
  }

  public func setRate(_ rate: Double) {
    synchronizer.setRate(Float(rate), time: .invalid)
  }

  public func seek(to seconds: Double) {
    let time = CMTime(seconds: seconds, preferredTimescale: 60000)
    synchronizer.setRate(0.0, time: time)
  }

  public func setTime(_ seconds: Double) {
    let time = CMTime(seconds: seconds, preferredTimescale: 60000)
    synchronizer.setRate(synchronizer.rate, time: time)
  }

  public var rate: Double {
    Double(synchronizer.rate)
  }

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
