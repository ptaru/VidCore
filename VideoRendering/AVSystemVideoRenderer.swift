//
//  AVSystemVideoRenderer.swift
//  VidCore
//
//  System-based video renderer using AVSampleBufferDisplayLayer
//  Provides reference HDR10/HLG rendering for comparison with custom Metal pipeline
//

import SwiftUI
import AVFoundation
import CoreMedia
import VideoToolbox

/// Renderer target that wraps AVSampleBufferDisplayLayer.
/// It is Sendable and can be called from background threads.
public final class LayerRenderer: VideoRendererTarget, SampleBufferRenderer, MediaDataReadinessAwaiting, @unchecked Sendable {
    public let displayLayer = AVSampleBufferDisplayLayer()
    private let readinessQueue = DispatchQueue(label: "VidCore.LayerRenderer.Readiness")
    private let readinessLock = NSLock()
    private var readinessWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isRequestingReadiness: Bool = false
    private let readinessTimeoutNanos: UInt64 = 250_000_000
    
    public init() {
        // Essential for proper HDR rendering on macOS
        displayLayer.preventsCapture = false
        displayLayer.videoGravity = .resizeAspect
    }
    
    public func enqueue(_ frame: VideoFrame) {
        guard let sampleBuffer = createSampleBuffer(from: frame) else { return }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        
        displayLayer.enqueue(sampleBuffer)
    }

    public var isReadyForMoreMediaData: Bool {
        displayLayer.isReadyForMoreMediaData
    }

    public func waitUntilReady() async {
        if displayLayer.isReadyForMoreMediaData {
            return
        }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                readinessLock.lock()
                readinessWaiters[waiterID] = continuation
                let shouldStart = !isRequestingReadiness
                if shouldStart {
                    isRequestingReadiness = true
                }
                readinessLock.unlock()

                Task {
                    try? await Task.sleep(nanoseconds: readinessTimeoutNanos)
                    var shouldStop = false
                    var waiter: CheckedContinuation<Void, Never>?
                    readinessLock.lock()
                    waiter = readinessWaiters.removeValue(forKey: waiterID)
                    shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
                    if shouldStop {
                        isRequestingReadiness = false
                    }
                    readinessLock.unlock()
                    if shouldStop {
                        displayLayer.stopRequestingMediaData()
                    }
                    waiter?.resume()
                }

                if shouldStart {
                    displayLayer.requestMediaDataWhenReady(on: readinessQueue) { [weak self] in
                        guard let self else { return }
                        guard self.displayLayer.isReadyForMoreMediaData else { return }

                        self.displayLayer.stopRequestingMediaData()

                        self.readinessLock.lock()
                        let waiters = self.readinessWaiters.values
                        self.readinessWaiters.removeAll()
                        self.isRequestingReadiness = false
                        self.readinessLock.unlock()

                        for waiter in waiters {
                            waiter.resume()
                        }
                    }
                }
            }
        } onCancel: {
            readinessLock.lock()
            let waiter = readinessWaiters.removeValue(forKey: waiterID)
            let shouldStop = readinessWaiters.isEmpty && isRequestingReadiness
            if shouldStop {
                isRequestingReadiness = false
            }
            readinessLock.unlock()

            if shouldStop {
                displayLayer.stopRequestingMediaData()
            }

            waiter?.resume()
        }
    }
    
    public func flush() {
        displayLayer.flush()
    }
    
    private func createSampleBuffer(from frame: VideoFrame) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(seconds: frame.presentationTime, preferredTimescale: 60000),
            decodeTimeStamp: CMTime.invalid
        )
        
        // Create format description
        // Use frame metadata to apply color attachments if they are missing (common for software decoders)
        let pixelBuffer = frame.pixelBuffer
        
        if frame.isHDR {
            frame.applyHDRAttachments()
        }
        
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard let formatDesc = formatDescription else { return nil }
        
        // Create the sample buffer
        let result = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        guard result == noErr, let buffer = sampleBuffer else { return nil }
        
        return buffer
    }
}

/// SwiftUI view that renders video frames using macOS system APIs (AVSampleBufferDisplayLayer).
public struct AVSystemVideoRenderer: NSViewRepresentable {
    let player: VideoPlayer
    
    public init(player: VideoPlayer) {
        self.player = player
    }
    
    public func makeNSView(context: Context) -> AVSampleBufferDisplayLayerWrapperView {
        let view = AVSampleBufferDisplayLayerWrapperView()
        // Connect the renderer to the player
        Task {
            await player.setRenderer(view.layerRenderer)
        }
        return view
    }
    
    public func updateNSView(_ view: AVSampleBufferDisplayLayerWrapperView, context: Context) {
        // No-op: Updates happen directly via the layerRenderer
    }
    
    /// Creates a CGImage from a VideoFrame using VideoToolbox, handling HDR and Dolby Vision.
    public static func createCGImage(from frame: VideoFrame) -> CGImage? {
        let pixelBuffer = frame.pixelBuffer
        
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
    public let layerRenderer = LayerRenderer()
    
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
