//
//  VideoPlayerError.swift
//  VidCore
//
//  Error types for video player operations
//

import Foundation

/// Error types for video player operations
public enum VideoPlayerError: Error, Equatable, LocalizedError, Sendable {
  case fileNotFound
  case decoderInitFailed(String)
  case unsupportedFormat
  case decodingFailed(String)
  case seekFailed

  public var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "Video file not found."
    case .decoderInitFailed(let message):
      return "Failed to initialise decoder: \(message)"
    case .unsupportedFormat:
      return "Video format is not supported."
    case .decodingFailed(let message):
      return "Decoding failed: \(message)"
    case .seekFailed:
      return "Failed to seek to the specified time."
    }
  }
}
