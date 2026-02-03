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

  func enqueue(_ buffer: AVAudioPCMBuffer, pts: Double, volume: Float)
  func flush()

  func play(rate: Double)
  func pause()
  func seek(to seconds: Double)
}
