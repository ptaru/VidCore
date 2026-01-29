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
public final class LayerRenderer: VideoRendererTarget, @unchecked Sendable {
    public let displayLayer = AVSampleBufferDisplayLayer()
    
    public init() {
        // Essential for proper HDR rendering on macOS
        displayLayer.preventsCapture = false
        displayLayer.videoGravity = .resizeAspect
    }
    
    public func enqueue(_ frame: VideoFrame) {
        guard let sampleBuffer = createSampleBuffer(from: frame) else { return }
        
        // AVSBDL requires the layer to be ready
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        
        displayLayer.enqueue(sampleBuffer)
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
        
        let cfAttachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)
        if let cfAttachments = cfAttachments {
            let count = CFArrayGetCount(cfAttachments)
            if count > 0 {
                let dict = CFArrayGetValueAtIndex(cfAttachments, 0)
                let mutableDict = unsafeBitCast(dict, to: CFMutableDictionary.self)
                
                let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
                let value = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                CFDictionarySetValue(mutableDict, key, value)
            }
        }
        
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

