//
//  DecodedFrame.swift
//  VidCore
//
//  A decoded frame from the video stream.
//

import AVFoundation
import Foundation

/// A decoded frame from the video stream.
///
/// Each frame can be either video (a ``VideoFrame`` with pixel data) or audio (a PCM buffer with its presentation timestamp).
public enum DecodedFrame {
    /// A decoded video frame with pixel buffer and timing.
    case video(VideoFrame)
    /// An audio buffer with its presentation timestamp in seconds.
    case audio(AVAudioPCMBuffer, Double)
}
