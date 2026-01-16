//
//  MetalVideoRenderer.swift
//  VidCore
//
//  NSViewRepresentable for Metal-based video rendering with HDR/EDR support
//

import SwiftUI
import MetalKit
import CoreVideo
import QuartzCore

/// SwiftUI view for Metal-based video rendering with HDR/EDR support
public struct MetalVideoRenderer: NSViewRepresentable {
    public let renderingEngine: RenderingEngine
    @Binding public var currentFrame: VideoFrame?

    public init(renderingEngine: RenderingEngine, currentFrame: Binding<VideoFrame?>) {
        self.renderingEngine = renderingEngine
        self._currentFrame = currentFrame
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = renderingEngine.device
        mtkView.delegate = context.coordinator
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.autoResizeDrawable = true
        return mtkView
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.parent = self
        
        // Configure layer for HDR/EDR when HDR or DoVi content is detected
        if let frame = currentFrame, (frame.isHDR || frame.doviMetadata != nil) {
            configureForHDR(nsView)
        }
        
        if currentFrame != nil {
            nsView.setNeedsDisplay(nsView.bounds)
        }
    }
    
    /// Configures the MTKView's CAMetalLayer for HDR/EDR output
    private func configureForHDR(_ view: MTKView) {
        guard let metalLayer = view.layer as? CAMetalLayer else { return }
        
        // Only configure once
        guard !metalLayer.wantsExtendedDynamicRangeContent else { return }
        
        // Enable EDR (Extended Dynamic Range)
        metalLayer.wantsExtendedDynamicRangeContent = true
        
        // Use 16-bit float format for HDR headroom (values > 1.0)
        metalLayer.pixelFormat = .rgba16Float
        view.colorPixelFormat = .rgba16Float
        
        // Set extended linear color space for proper color management
        // Display P3 is more widely supported than BT.2020 on macOS
        if let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
            metalLayer.colorspace = colorSpace
        }
        
        print("[MetalVideoRenderer] Configured layer for HDR/EDR output")
    }

    public class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalVideoRenderer

        init(_ parent: MetalVideoRenderer) {
            self.parent = parent
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            guard let currentFrame = parent.currentFrame else { return }
            guard let drawable = view.currentDrawable else { return }
            
            // Use HDR-aware rendering method
            parent.renderingEngine.renderVideoFrame(currentFrame, to: drawable)
        }
    }
}
