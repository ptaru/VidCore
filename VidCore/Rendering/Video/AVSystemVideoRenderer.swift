//
//  AVSystemVideoRenderer.swift
//  VidCore
//
//  System-based video renderer using AVSampleBufferDisplayLayer
//
//

import AVFoundation
import CoreMedia
import SwiftUI
import VideoToolbox

// Fix for Sendable warning
extension AVSampleBufferDisplayLayer: @unchecked @retroactive Sendable {}

/// Renderer target that wraps AVSampleBufferDisplayLayer.
/// It is Sendable and can be called from background threads.
public actor LayerRenderer: VideoRendererTarget, SampleBufferRenderer, MediaDataReadinessAwaiting {
  public nonisolated let displayLayer = AVSampleBufferDisplayLayer()
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var isRequestingReadiness: Bool = false

  /// Creates a new layer renderer.
  public init() {
    // Essential for proper HDR rendering on macOS
    displayLayer.preventsCapture = false
    displayLayer.videoGravity = .resizeAspect
  }

  /// Enqueues a video frame for display.
  /// - Parameter frame: The video frame to display.
  public nonisolated func enqueue(_ frame: VideoFrame) async {
    await _enqueue(frame)
  }

  private func _enqueue(_ frame: VideoFrame) {
    if displayLayer.sampleBufferRenderer.status == .failed {
      displayLayer.sampleBufferRenderer.flush()
    }

    // Ensure the sample buffer is ready for display (attachments, etc are handled in VideoFrame)
    displayLayer.sampleBufferRenderer.enqueue(frame.sampleBuffer)
  }

  /// Whether the renderer is ready to accept more media data.
  public nonisolated var isReadyForMoreMediaData: Bool {
    displayLayer.sampleBufferRenderer.isReadyForMoreMediaData
  }

  /// Waits until the renderer is ready for more data.
  public func waitUntilReady() async {
    let renderer = displayLayer.sampleBufferRenderer
    if renderer.isReadyForMoreMediaData {
      return
    }

    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)

        if !isRequestingReadiness {
          isRequestingReadiness = true
          renderer.requestMediaDataWhenReady(on: .global()) { [weak self] in
            guard let self else { return }
            Task {
              await self.resolveWaiters()
            }
          }
        }
      }
    } onCancel: {
      Task {
        await self.resolveWaiters()
      }
    }
  }

  private func resolveWaiters() {
    let currentWaiters = waiters
    waiters.removeAll()
    isRequestingReadiness = false
    displayLayer.sampleBufferRenderer.stopRequestingMediaData()
    for waiter in currentWaiters {
      waiter.resume()
    }
  }

  /// Flushes the video renderer.
  public nonisolated func flush() {
    displayLayer.sampleBufferRenderer.flush()
    Task {
      await self.resolveWaiters()
    }
  }
}

/// SwiftUI view that renders video frames using macOS system APIs (AVSampleBufferDisplayLayer).
public struct AVSystemVideoRenderer: NSViewRepresentable {
  let player: MediaPlayer

  /// Creates a new system video renderer view.
  /// - Parameter player: The video player to display.
  public init(player: MediaPlayer) {
    self.player = player
  }

  /// Creates the underlying NSView.
  public func makeNSView(context: Context) -> AVSampleBufferDisplayLayerWrapperView {
    let view = AVSampleBufferDisplayLayerWrapperView()
    // Connect the renderer and display source to the player
    Task { @MainActor in
      await player.setRenderer(view.layerRenderer)
      player.setDisplayLinkSource(view)
    }
    return view
  }

  /// Updates the NSView when SwiftUI state changes.
  public func updateNSView(_ view: AVSampleBufferDisplayLayerWrapperView, context: Context) {
    // No-op: Updates happen directly via the layerRenderer
  }

  /// Creates a CGImage from a VideoFrame using VideoToolbox, handling HDR and Dolby Vision.
  /// - Parameter frame: The video frame to convert.
  /// - Returns: A CGImage representation of the frame, or `nil` if conversion fails.
  public static func createCGImage(from frame: VideoFrame) -> CGImage? {
    guard let pixelBuffer = frame.pixelBuffer else { return nil }

    if frame.isHDR {
      frame.applyHDRAttachments()
    }

    var cgImage: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)

    return cgImage
  }
}

/// NSView wrapper for AVSampleBufferDisplayLayer
public class AVSampleBufferDisplayLayerWrapperView: NSView {
  /// The underlying layer renderer.
  public let layerRenderer = LayerRenderer()

  /// Creates a new wrapper view.
  override public init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupLayer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupLayer()
  }

  private func setupLayer() {
    self.wantsLayer = true
    self.layer = layerRenderer.displayLayer
  }

  override public func layout() {
    super.layout()
    layerRenderer.displayLayer.frame = self.bounds
  }
}
