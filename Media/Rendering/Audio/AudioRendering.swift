//
//  AudioRendering.swift
//  VidCore
//
//  Protocol for audio output backends.
//

import AVFoundation
import Foundation

public protocol AudioRendering: AnyObject, Sendable {
  var isEnabled: Bool { get }
  var isReadyForMoreMediaData: Bool { get }
  func waitUntilReady() async

  func setVolume(_ volume: Float)
  func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float)
  func flush() async

  /// Synchronize the renderer's playback state with an external clock.
  /// - Parameters:
  ///   - isPlaying: Whether playback should be active
  ///   - rate: Playback rate (e.g., 1.0 = normal speed, 2.0 = double speed)
  func setPlaybackState(isPlaying: Bool, rate: Double)
}
