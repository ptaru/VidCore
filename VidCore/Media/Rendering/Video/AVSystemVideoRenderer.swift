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
  private var readinessWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  private var isRequestingReadiness: Bool = false
  private let readinessTimeoutNanos: UInt64 = 250_000_000

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
    if displayLayer.sampleBufferRenderer.isReadyForMoreMediaData {
      return
    }

    let waiterID = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        readinessWaiters[waiterID] = continuation
        let shouldStart = !isRequestingReadiness
        if shouldStart {
          isRequestingReadiness = true
        }

        Task {
          try? await Task.sleep(nanoseconds: readinessTimeoutNanos)
          var shouldStop = false
          var waiter: CheckedContinuation<Void, Never>?
          self.timeoutWaiter(waiterID: waiterID) { stop, w in
            shouldStop = stop
            waiter = w
          }
          if shouldStop {
            self.displayLayer.sampleBufferRenderer.stopRequestingMediaData()
          }
          waiter?.resume()
        }

        if shouldStart {
          self.displayLayer.sampleBufferRenderer.requestMediaDataWhenReady(
            on: DispatchQueue.global(qos: .userInteractive)
          ) { [weak self] in
            guard let self else { return }
            guard self.displayLayer.sampleBufferRenderer.isReadyForMoreMediaData else { return }

            self.displayLayer.sampleBufferRenderer.stopRequestingMediaData()

            // Use detached task with high priority to jump back to actor context immediately
            Task.detached(priority: .userInteractive) {
              await self.resumeAllWaiters()
            }
          }
        }
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(waiterID: waiterID)
      }
    }
  }

  private func timeoutWaiter(
    waiterID: UUID, completion: (Bool, CheckedContinuation<Void, Never>?) -> Void
  ) {
    let waiter = readinessWaiters.removeValue(forKey: waiterID)
    let shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
    if shouldStop {
      isRequestingReadiness = false
    }
    completion(shouldStop, waiter)
  }

  private func resumeAllWaiters() {
    let waiters = readinessWaiters.values
    readinessWaiters.removeAll()
    isRequestingReadiness = false

    for waiter in waiters {
      waiter.resume()
    }
  }

  private func cancelWaiter(waiterID: UUID) {
    let waiter = readinessWaiters.removeValue(forKey: waiterID)
    let shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
    if shouldStop {
      isRequestingReadiness = false
    }

    if shouldStop {
      displayLayer.sampleBufferRenderer.stopRequestingMediaData()
    }

    waiter?.resume()
  }

  /// Flushes the video renderer.
  public nonisolated func flush() {
    displayLayer.sampleBufferRenderer.flush()
  }
}

/// SwiftUI view that renders video frames using macOS system APIs (AVSampleBufferDisplayLayer).
public struct AVSystemVideoRenderer: NSViewRepresentable {
  let player: VideoPlayer

  /// Creates a new system video renderer view.
  /// - Parameter player: The video player to display.
  public init(player: VideoPlayer) {
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
