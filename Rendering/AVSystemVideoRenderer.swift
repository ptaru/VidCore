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

/// SwiftUI view that renders video frames using macOS system APIs (AVSampleBufferDisplayLayer).
/// This serves as a "reference" renderer to verify custom HDR/HLG processing.
public struct AVSystemVideoRenderer: NSViewRepresentable {
    public let currentFrame: VideoFrame?
    
    public init(currentFrame: VideoFrame?) {
        self.currentFrame = currentFrame
    }
    
    public func makeNSView(context: Context) -> AVSampleBufferDisplayLayerWrapperView {
        let view = AVSampleBufferDisplayLayerWrapperView()
        return view
    }
    
    public func updateNSView(_ view: AVSampleBufferDisplayLayerWrapperView, context: Context) {
        if let frame = currentFrame {
            view.enqueue(frame)
        }
    }
    
    /// Creates a CGImage from a VideoFrame using VideoToolbox, handling HDR and Dolby Vision.
    /// - Parameter frame: The video frame to convert
    /// - Returns: A CGImage representation of the frame, or nil if conversion fails.
    public static func createCGImage(from frame: VideoFrame) -> CGImage? {
        var frameToProcess = frame
        let doviConverter = DoViHDR10Converter()
        
        // Check for Dolby Vision Profile 5 (which needs conversion)
        if frame.doviProfile == 5 {
            // "Profile 5" check: IPTPQc2 requires custom conversion
            // Convert to HDR10 (RGBA16Float)
            if let converted = doviConverter?.convert(frame: frame) {
                frameToProcess = converted
            }
        }
        
        let pixelBuffer = frameToProcess.pixelBuffer
        
        if frameToProcess.isHDR {
            // Most HDR content is BT.2020
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            
            // Transfer Function
            let transferFunction: CFString
            if frameToProcess.colorTransfer == 18 { // HLG
                transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            } else { // PQ (ST 2084)
                transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            }
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, transferFunction, .shouldPropagate)
            
            // Apply Dolby Vision L1 metadata if present (Dynamic HDR10)
            if let seiPayload = frameToProcess.doviMetadata?.contentLightLevelData() {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, seiPayload as CFData, .shouldPropagate)
            }
        }
        
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        
        return cgImage
    }
}

/// NSView wrapper for AVSampleBufferDisplayLayer
public class AVSampleBufferDisplayLayerWrapperView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let doviConverter = DoViHDR10Converter()
    
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        // Essential for proper HDR rendering on macOS
        // "preventsCapture" defaults to false, which allows screen recording/screenshots
        // to capture the content (often tone-mapped to SDR if the capture doesn't support HDR).
        displayLayer.preventsCapture = false
        displayLayer.videoGravity = .resizeAspect
        
        // Host the layer
        self.wantsLayer = true
        self.layer = displayLayer
    }
    
    // Ensure layer resizes with view
    override public func layout() {
        super.layout()
        displayLayer.frame = self.bounds
    }
    
    /// Enqueues a video frame for display
    func enqueue(_ frame: VideoFrame) {
        var frameToDisplay = frame
        
        // Check for Dolby Vision Profile 5 (which needs conversion for System Renderer)
        if frame.doviProfile == 5 {
            // "Profile 5" check: IPTPQc2 requires custom conversion
            // Convert to HDR10 (RGBA16Float)
            if let converted = doviConverter?.convert(frame: frame) {
                frameToDisplay = converted
            }
        }
        
        guard let sampleBuffer = createSampleBuffer(from: frameToDisplay) else { return }
        
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
            // Most HDR content is BT.2020
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            
            // Transfer Function
            let transferFunction: CFString
            if frame.colorTransfer == 18 { // HLG
                transferFunction = kCVImageBufferTransferFunction_ITU_R_2100_HLG
            } else { // PQ (ST 2084)
                transferFunction = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
            }
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, transferFunction, .shouldPropagate)
            
            // Apply Dolby Vision L1 metadata if present (Dynamic HDR10)
            if let seiPayload = frame.doviMetadata?.contentLightLevelData() {
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, seiPayload as CFData, .shouldPropagate)
            }
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
