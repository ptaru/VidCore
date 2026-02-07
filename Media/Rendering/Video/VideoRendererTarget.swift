//
//  VideoRendererTarget.swift
//  VidCore
//
//  Protocol for objects that can receive video frames for display
//

import Foundation

/// Protocol for objects that can receive video frames for display.
/// This allows the display loop to be decoupled from the specific rendering implementation.
public protocol VideoRendererTarget: AnyObject, Sendable {
  /// Enqueue a frame for display
  func enqueue(_ frame: VideoFrame) async
}

/// Optional protocol for renderers that can await readiness without polling.
public protocol MediaDataReadinessAwaiting: AnyObject, Sendable {
  func waitUntilReady() async
}

/// Optional protocol for renderers that accept sample buffers and can be flushed.
public protocol SampleBufferRenderer: AnyObject, Sendable {
  var isReadyForMoreMediaData: Bool { get }
  func flush()
}
