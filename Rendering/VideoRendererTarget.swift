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
    func enqueue(_ frame: VideoFrame)
}
