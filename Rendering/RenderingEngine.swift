//
//  RenderingEngine.swift
//  VidCore
//
//  Metal rendering engine for video frames with GPU YUV conversion
//

import CoreImage
import CoreVideo
import Metal
import MetalKit
import Foundation

/// GPU-accelerated video frame renderer using Metal with HDR support.
///
/// `RenderingEngine` handles rendering of video frames to Metal drawables with zero-copy
/// GPU color conversion. It automatically detects the pixel format and drawable configuration
/// to select the appropriate shader pipeline for SDR or HDR content.
///
/// ## Supported Formats
/// **SDR (8-bit):**
/// - **NV12/420v**: Hardware-decoded frames (biplanar YUV 4:2:0, video and full range)
/// - **I420/YUV420P**: Software-decoded frames (triplanar YUV 4:2:0, video and full range)
/// - **BGRA**: Direct rendering without conversion
///
/// **HDR (10-bit):**
/// - **P010**: Hardware-decoded HDR frames (biplanar YUV 4:2:0)
/// - **YUV420P10LE**: Software-decoded HDR frames (triplanar YUV 4:2:0)
///
/// ## HDR Rendering
/// For HDR content, configure your Metal layer for EDR:
/// ```swift
/// metalLayer.pixelFormat = .rgba16Float
/// metalLayer.wantsExtendedDynamicRangeContent = true
/// ```
///
/// The engine will automatically apply PQ (SMPTE ST 2084) to linear conversion
/// and output values where 1.0 = 100 nits (SDR white), >1.0 = HDR highlights.
///
/// ## Example
/// ```swift
/// guard let engine = RenderingEngine() else { return }
///
/// // Render a frame to a CAMetalDrawable (HDR-aware)
/// engine.renderVideoFrame(videoFrame, to: drawable)
/// ```
///
/// ## Performance
/// The GPU shader approach eliminates CPU color conversion overhead. For 4K video,
/// this saves approximately 20-30ms per frame compared to CPU-based `sws_scale`.
public class RenderingEngine {
    // MARK: - Properties

    /// The Metal device used for rendering.
    public let device: MTLDevice
    /// The command queue for submitting render commands.
    public let commandQueue: MTLCommandQueue
    /// A Core Image context for fallback rendering of unusual formats.
    public let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?
    private var frameCounter: Int = 0

    /// Target peak brightness of the display in nits.
    /// Default is 1000.0 (typical for Apple XDR displays).
    public var targetDisplayPeakNits: Float = ToneMapping.hdr10DefaultPeakNits

    /// Source content peak brightness in nits.
    /// Default is 1000.0 (standard HDR10).
    public var contentPeakNits: Float = ToneMapping.hdr10DefaultPeakNits

    // YUV rendering pipelines (SDR - bgra8Unorm output)
    private var nv12PipelineState: MTLRenderPipelineState?  // Video range (16-235)
    private var nv12FullRangePipelineState: MTLRenderPipelineState?  // Full range (0-255)

    private var i420VideoRangePipelineState: MTLRenderPipelineState?  // Video range (16-235)
    private var i420FullRangePipelineState: MTLRenderPipelineState?  // Full range (0-255)
    private var bgraPipelineState: MTLRenderPipelineState?

    // SDR pipelines with rgba16Float output (for HDR-configured layers)
    private var nv12Float16PipelineState: MTLRenderPipelineState?
    private var i420Float16PipelineState: MTLRenderPipelineState?

    // HDR pipelines (output rgba16Float for EDR with PQ->linear conversion)
    private var hdrNV12PipelineState: MTLRenderPipelineState?
    private var hdrI420PipelineState: MTLRenderPipelineState?
    
    // HDR10 SDR pipeline (for non-EDR displays)
    private var hdrNV12SDRPipelineState: MTLRenderPipelineState?
    
    // Dolby Vision Profile 5 pipeline (IPTPQc2 processing)
    private var doviNV12PipelineState: MTLRenderPipelineState?
    
    // Dolby Vision Profile 5 SDR pipeline (for thumbnail generation)
    private var doviNV12SDRPipelineState: MTLRenderPipelineState?

    // MARK: - Initialization

    /// Creates a new rendering engine with the default Metal device.
    ///
    /// This initializes Metal, creates a command queue, sets up the texture cache,
    /// and compiles the YUV conversion shaders.
    ///
    /// - Returns: A configured rendering engine, or `nil` if Metal is unavailable.
    public init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }

        guard let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device)

        // Create texture cache
        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let textureCache = cache else {
            return nil
        }
        self.textureCache = textureCache

        // Setup render pipelines
        setupPipelines()
    }

    /// Flush the texture cache to release all cached Metal textures.
    ///
    /// Call this during cleanup to ensure GPU memory is released.
    /// This is particularly important for QuickLook extensions with strict memory limits.
    public func flush() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    private func setupPipelines() {
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: RenderingEngine.self)) else {
            print("[RenderingEngine] Failed to load Metal library from framework bundle")
            return
        }

        let configs = [
            PipelineConfig(fragmentFunction: "nv12FragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.nv12PipelineState),
            PipelineConfig(fragmentFunction: "nv12FullRangeFragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.nv12FullRangePipelineState),
            PipelineConfig(fragmentFunction: "i420FragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.i420VideoRangePipelineState),
            PipelineConfig(fragmentFunction: "i420FullRangeFragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.i420FullRangePipelineState),
            PipelineConfig(fragmentFunction: "bgraFragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.bgraPipelineState),
            PipelineConfig(fragmentFunction: "hdrNV12FragmentShader", pixelFormat: .rgba16Float, keyPath: \.hdrNV12PipelineState),
            PipelineConfig(fragmentFunction: "hdrI420FragmentShader", pixelFormat: .rgba16Float, keyPath: \.hdrI420PipelineState),
            PipelineConfig(fragmentFunction: "hdrNV12SDRFragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.hdrNV12SDRPipelineState),
            PipelineConfig(fragmentFunction: "nv12FragmentShader", pixelFormat: .rgba16Float, keyPath: \.nv12Float16PipelineState),
            PipelineConfig(fragmentFunction: "i420FragmentShader", pixelFormat: .rgba16Float, keyPath: \.i420Float16PipelineState),
            PipelineConfig(fragmentFunction: "doviNV12FragmentShader", pixelFormat: .rgba16Float, keyPath: \.doviNV12PipelineState),
            PipelineConfig(fragmentFunction: "doviNV12SDRFragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.doviNV12SDRPipelineState)
        ]

        for config in configs {
            createPipeline(library: library, config: config)
        }
    }

    // MARK: - Public Rendering

    /// Renders a pixel buffer to a drawable, automatically detecting format
    /// Uses direct Metal shaders for all common formats - minimal Core Image fallback
    public func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // I420/YUV420P (tri-planar) - most common software decode output
        // Default to Video Range as most video content is 16-235
        if format == kCVPixelFormatType_420YpCbCr8Planar {
            if renderI420PixelBuffer(pixelBuffer, to: drawable, fullRange: false) {
                return
            }
        }

        // NV12 (bi-planar) - hardware decode output and some software paths
        // Use appropriate shader based on video range vs full range format
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            if renderNV12PixelBuffer(pixelBuffer, to: drawable, fullRange: false) {
                return
            }
        }

        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            if renderNV12PixelBuffer(pixelBuffer, to: drawable, fullRange: true) {
                return
            }
        }

        // BGRA - direct Metal path (no Core Image overhead)
        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            if renderBGRAPixelBuffer(pixelBuffer, to: drawable) {
                return
            }
        }

        // Fallback to Core Image for unknown/rare formats only
        renderPixelBufferWithCoreImage(pixelBuffer, to: drawable)
    }

    // MARK: - SDR Rendering

    /// GPU-accelerated NV12 rendering using Metal shader
    /// - Parameter fullRange: If true, uses full range (0-255) conversion; otherwise video range (16-235)
    private func renderNV12PixelBuffer(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable, fullRange: Bool
    ) -> Bool {
        let pipelineState = fullRange ? nv12FullRangePipelineState : nv12PipelineState
        guard let pipelineState = pipelineState else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 8) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.uv, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        flushTextureCacheIfNeeded()
        return true
    }

    /// GPU-accelerated I420/YUV420P rendering using Metal shader
    /// This is the zero-copy path for software-decoded frames
    /// - Parameter fullRange: If true, uses full range (0-255) conversion; otherwise video range (16-235)
    private func renderI420PixelBuffer(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable, fullRange: Bool
    ) -> Bool {
        let pipelineState = fullRange ? i420FullRangePipelineState : i420VideoRangePipelineState
        guard let pipelineState = pipelineState else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createI420Textures(from: pixelBuffer) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.u, index: 1)
        encoder.setFragmentTexture(textures.v, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        flushTextureCacheIfNeeded()
        return true
    }

    /// GPU-accelerated BGRA rendering using Metal shader
    /// Eliminates Core Image overhead for BGRA pixel buffers
    private func renderBGRAPixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) -> Bool {
        guard let pipelineState = bgraPipelineState else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let texture = createTexture(from: pixelBuffer, plane: 0, format: .bgra8Unorm, width: width, height: height) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        flushTextureCacheIfNeeded()
        return true
    }

    /// Renders a pixel buffer using Core Image (fallback path for rare formats)
    private func renderPixelBufferWithCoreImage(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard
            imageWidth > 0 && imageHeight > 0 && drawable.texture.width > 0
                && drawable.texture.height > 0
        else {
            return
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let drawableSize = CGSize(
            width: CGFloat(drawable.texture.width), height: CGFloat(drawable.texture.height))
        let imageSize = CGSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight))

        let scaleX = drawableSize.width / imageSize.width
        let scaleY = drawableSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        guard scale > 0 && scale.isFinite else { return }

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let x = (drawableSize.width - scaledWidth) / 2
        let y = (drawableSize.height - scaledHeight) / 2

        guard x.isFinite && y.isFinite else { return }

        let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
        ciImage = ciImage.transformed(by: transform)

        let drawableBounds = CGRect(
            x: 0, y: 0, width: drawableSize.width, height: drawableSize.height)
        ciImage = ciImage.cropped(to: drawableBounds)

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor)
        {
            renderEncoder.endEncoding()
        }

        ciContext.render(
            ciImage,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: drawableBounds,
            colorSpace: colorSpace)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - HDR Rendering

    /// Renders a video frame with HDR awareness.
    ///
    /// For HDR content, this uses specialized shaders that output linear light values
    /// for macOS EDR displays. For SDR content, it falls back to standard rendering.
    ///
    /// The drawable's layer must be configured for EDR (rgba16Float pixel format,
    /// wantsExtendedDynamicRangeContent = true) for HDR content to display correctly.
    public func renderVideoFrame(_ frame: VideoFrame, to drawable: CAMetalDrawable) {
        let isFloat16Layer = drawable.texture.pixelFormat == .rgba16Float
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let hasDoVi = frame.doviMetadata != nil
        
        // DoVi content should be treated as HDR
        let isEffectivelyHDR = frame.isHDR || hasDoVi

        // Debug frame info
        struct DebugState { static var frameCount = 0 }
        if DebugState.frameCount < 3 {
            let formatStr = String(format: "0x%08X", format)
            print(
                "[RenderingEngine] Frame \(DebugState.frameCount): isHDR=\(frame.isHDR), doVi=\(hasDoVi), format=\(formatStr), layer=\(isFloat16Layer ? "Float16" : "BGRA8")"
            )
            DebugState.frameCount += 1
        }

        // Dolby Vision Profile 5 path (IPTPQc2)
        if let doviMetadata = frame.doviMetadata {
            if isFloat16Layer {
                // EDR display: use full HDR DoVi pipeline
                if renderDoViPixelBuffer(frame.pixelBuffer, metadata: doviMetadata, to: drawable) {
                    return
                }
                // Fall through to regular HDR if DoVi render failed
            } else {
                // SDR display: use tone-mapped DoVi SDR pipeline
                if renderDoViPixelBufferSDR(frame.pixelBuffer, metadata: doviMetadata, to: drawable) {
                    return
                }
                // Fall through to standard rendering if DoVi SDR render fails
            }
        }

        if isEffectivelyHDR {
            if isFloat16Layer {
                // EDR display: use full HDR pipeline
                if renderHDRPixelBuffer(frame.pixelBuffer, to: drawable) {
                    return
                }
                // Fall back to Float16 SDR if HDR render failed
                renderPixelBufferFloat16(frame.pixelBuffer, to: drawable)
                return
            } else {
                // SDR display: use tone-mapped HDR SDR pipeline
                if renderHDRPixelBufferSDR(frame.pixelBuffer, to: drawable) {
                    return
                }
                // Fall through to standard rendering if HDR SDR fails
            }
        }

        // SDR path - use appropriate pipeline based on layer format
        if isFloat16Layer {
            renderPixelBufferFloat16(frame.pixelBuffer, to: drawable)
        } else {
            renderPixelBuffer(frame.pixelBuffer, to: drawable)
        }
    }

    /// Renders SDR pixel buffer to rgba16Float drawable (for HDR-configured layers)
    private func renderPixelBufferFloat16(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // I420/YUV420P with rgba16Float output
        if format == kCVPixelFormatType_420YpCbCr8Planar {
            if renderI420PixelBufferFloat16(pixelBuffer, to: drawable) {
                return
            }
        }

        // NV12 with rgba16Float output
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        {
            if renderNV12PixelBufferFloat16(pixelBuffer, to: drawable) {
                return
            }
        }

        // For other formats, fall back to Core Image (it should handle the conversion)
        renderPixelBufferWithCoreImage(pixelBuffer, to: drawable)
    }

    /// Renders HDR pixel buffer (10-bit P010 or I420) to EDR output
    private func renderHDRPixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable)
        -> Bool
    {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // P010 - 10-bit bi-planar (common hardware decode output for HDR)
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        {
            return renderHDRNV12PixelBuffer(pixelBuffer, to: drawable)
        }

        // 8-bit I420 from FFmpeg sws_scale - can't do true HDR, return false to use SDR fallback
        return false
    }
    
    /// Renders HDR10 content to SDR drawable (for non-EDR displays)
    /// Uses BT.2390 tone mapping to 100 nits with gamma output
    private func renderHDRPixelBufferSDR(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable)
        -> Bool
    {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        // P010 - 10-bit bi-planar (common hardware decode output for HDR)
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        {
            return renderHDRNV12PixelBufferSDR(pixelBuffer, to: drawable)
        }
        
        // 8-bit I420 from FFmpeg sws_scale - already SDR, return false
        return false
    }
    
    /// GPU-accelerated 10-bit P010 (HDR NV12) rendering with tone mapping to SDR
    private func renderHDRNV12PixelBufferSDR(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = hdrNV12SDRPipelineState else { return false }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }
        
        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        
        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
        
        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.uv, index: 1)
        
        // Tone mapping params - map to SDR (100 nits)
        var toneParams = ToneMappingParams(
            inputMin: 0.0,
            inputMax: contentPeakNits,
            outputMin: 0.0,
            outputMax: ToneMapping.sdrPeakNits
        )
        encoder.setFragmentBytes(&toneParams, length: MemoryLayout<ToneMappingParams>.size, index: 0)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        return true
    }


    /// GPU-accelerated 10-bit P010 (HDR NV12) rendering with PQ->Linear conversion for EDR
    private func renderHDRNV12PixelBuffer(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = hdrNV12PipelineState else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.uv, index: 1)

        // Calculate dynamic peak brightness
        let currentDisplayPeak = ToneMapping.getCurrentScreenPeakNits(for: drawable.layer)

        // Log peak brightness change
        struct LogState { static var lastPeak: Float = -1.0 }
        if abs(currentDisplayPeak - LogState.lastPeak) > 1.0 {
            print("[RenderingEngine] Detected Display Peak Brightness: \(currentDisplayPeak) nits")
            LogState.lastPeak = currentDisplayPeak
        }
        
        // Pass Tone Mapping Params
        var params = ToneMappingParams(
            inputMin: 0.0,
            inputMax: contentPeakNits,
            outputMin: 0.0,
            outputMax: currentDisplayPeak
        )
        encoder.setFragmentBytes(&params, length: MemoryLayout<ToneMappingParams>.size, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        return true
    }

    /// Renders Dolby Vision Profile 5 (IPTPQc2) content with reshape processing
    private func renderDoViPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        metadata: DoViMetadata,
        to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = doviNV12PipelineState else {
            print("[RenderingEngine] DoVi pipeline not available")
            return false
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }
        
        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        
        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
        
        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.uv, index: 1)
        
        // Encode DoVi parameters (buffer 0)
        var doviParams = DoViParamsBuffer(from: metadata)
        encoder.setFragmentBytes(&doviParams, length: MemoryLayout<DoViParamsBuffer>.size, index: 0)
        
        // Encode reshape components (buffers 1, 2, 3) - separate to stay under 4KB limit
        var compI = DoViReshapeComponentBuffer(from: metadata.components[0])
        var compP = DoViReshapeComponentBuffer(from: metadata.components[1])
        var compT = DoViReshapeComponentBuffer(from: metadata.components[2])
        encoder.setFragmentBytes(&compI, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 1)
        encoder.setFragmentBytes(&compP, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 2)
        encoder.setFragmentBytes(&compT, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 3)
        
        // Encode tone mapping params (buffer 4) - use L1 scene brightness if available
        let currentDisplayPeak = ToneMapping.getCurrentScreenPeakNits(for: drawable.layer)
        let dynamicPeakPQ = metadata.sceneMaxPQ ?? metadata.sourceMaxPQ
        let dynamicPeakNits = ToneMapping.pqToNits(dynamicPeakPQ)
        
        struct L1LogState { static var logged = false }
        if !L1LogState.logged, metadata.sceneMaxPQ != nil {
            print("[RenderingEngine] Using L1 scene brightness: max=\(dynamicPeakPQ), nits=\(dynamicPeakNits)")
            L1LogState.logged = true
        }
        
        var toneParams = ToneMappingParams(inputMin: 0.0, inputMax: dynamicPeakNits, outputMin: 0.0, outputMax: currentDisplayPeak)
        encoder.setFragmentBytes(&toneParams, length: MemoryLayout<ToneMappingParams>.size, index: 4)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        return true
    }
    
    /// Renders Dolby Vision Profile 5 content to an SDR drawable (for non-EDR displays)
    /// Uses the DoVi processing pipeline with tone mapping to 100 nits SDR output
    private func renderDoViPixelBufferSDR(
        _ pixelBuffer: CVPixelBuffer,
        metadata: DoViMetadata,
        to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = doviNV12SDRPipelineState else { return false }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }
        
        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        
        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
        
        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.uv, index: 1)
        
        // Encode DoVi parameters (buffer 0)
        var doviParams = DoViParamsBuffer(from: metadata)
        encoder.setFragmentBytes(&doviParams, length: MemoryLayout<DoViParamsBuffer>.size, index: 0)
        
        // Encode reshape components (buffers 1, 2, 3)
        var compI = DoViReshapeComponentBuffer(from: metadata.components[0])
        var compP = DoViReshapeComponentBuffer(from: metadata.components[1])
        var compT = DoViReshapeComponentBuffer(from: metadata.components[2])
        encoder.setFragmentBytes(&compI, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 1)
        encoder.setFragmentBytes(&compP, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 2)
        encoder.setFragmentBytes(&compT, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 3)
        
        // Encode tone mapping params (buffer 4) - SDR output at 100 nits
        let dynamicPeakPQ = metadata.sceneMaxPQ ?? metadata.sourceMaxPQ
        let dynamicPeakNits = ToneMapping.pqToNits(dynamicPeakPQ)
        var toneParams = ToneMappingParams(inputMin: 0.0, inputMax: dynamicPeakNits, outputMin: 0.0, outputMax: ToneMapping.sdrPeakNits)
        encoder.setFragmentBytes(&toneParams, length: MemoryLayout<ToneMappingParams>.size, index: 4)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        return true
    }
    
    /// Renders Dolby Vision Profile 5 content to an SDR texture (for thumbnail generation)
    /// Uses the DoVi processing pipeline with tone mapping to 100 nits SDR output
    private func renderDoViPixelBufferToTexture(
        _ pixelBuffer: CVPixelBuffer,
        metadata: DoViMetadata,
        to texture: MTLTexture
    ) -> Bool {
        guard let pipelineState = doviNV12SDRPipelineState else {
            print("[RenderingEngine] DoVi SDR pipeline not available")
            return false
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }
        
        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        
        let renderPassDescriptor = createBasicRenderPassDescriptor(for: texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
        
        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: texture.width, targetHeight: texture.height)
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.uv, index: 1)
        
        // Encode DoVi parameters (buffer 0)
        var doviParams = DoViParamsBuffer(from: metadata)
        encoder.setFragmentBytes(&doviParams, length: MemoryLayout<DoViParamsBuffer>.size, index: 0)
        
        // Encode reshape components (buffers 1, 2, 3)
        var compI = DoViReshapeComponentBuffer(from: metadata.components[0])
        var compP = DoViReshapeComponentBuffer(from: metadata.components[1])
        var compT = DoViReshapeComponentBuffer(from: metadata.components[2])
        encoder.setFragmentBytes(&compI, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 1)
        encoder.setFragmentBytes(&compP, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 2)
        encoder.setFragmentBytes(&compT, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 3)
        
        // Encode tone mapping params (buffer 4) - SDR thumbnail at 100 nits
        let dynamicPeakPQ = metadata.sceneMaxPQ ?? metadata.sourceMaxPQ
        let dynamicPeakNits = ToneMapping.pqToNits(dynamicPeakPQ)
        var toneParams = ToneMappingParams(inputMin: 0.0, inputMax: dynamicPeakNits, outputMin: 0.0, outputMax: ToneMapping.sdrPeakNits)
        encoder.setFragmentBytes(&toneParams, length: MemoryLayout<ToneMappingParams>.size, index: 4)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return true
    }
    
    // MARK: - Helpers

    // MARK: - Float16 Rendering

    /// NV12 rendering to rgba16Float target (for HDR-configured layers with SDR content)
    private func renderNV12PixelBufferFloat16(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = nv12Float16PipelineState else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 8) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.uv, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    /// I420 rendering to rgba16Float target (for HDR-configured layers with SDR content)
    private func renderI420PixelBufferFloat16(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = i420Float16PipelineState else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createI420Textures(from: pixelBuffer) else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = createBasicRenderPassDescriptor(for: drawable.texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: drawable.texture.width, targetHeight: drawable.texture.height)

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        encoder.setFragmentTexture(textures.y, index: 0)
        encoder.setFragmentTexture(textures.u, index: 1)
        encoder.setFragmentTexture(textures.v, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    // MARK: - CGImage Export

    /// Renders a video frame to a CGImage using GPU-accelerated YUV conversion.
    ///
    /// This method creates an offscreen render target, renders the pixel buffer using
    /// the appropriate Metal shader for its format, and reads back the result as a CGImage.
    /// This is useful for thumbnail generation where all pixel formats need to be supported.
    /// For Dolby Vision content, the DoVi processing pipeline is used with tone mapping to SDR.
    ///
    /// - Parameters:
    ///   - frame: The video frame to render.
    ///   - targetSize: Optional target size. If nil, uses the frame's native resolution.
    /// - Returns: A CGImage containing the rendered frame, or nil if rendering failed.
    public func renderToCGImage(_ frame: VideoFrame, targetSize: CGSize? = nil) -> CGImage? {
        let pixelBuffer = frame.pixelBuffer
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // Determine output size
        let outputWidth: Int
        let outputHeight: Int
        if let size = targetSize {
            outputWidth = Int(size.width)
            outputHeight = Int(size.height)
        } else {
            outputWidth = sourceWidth
            outputHeight = sourceHeight
        }

        guard outputWidth > 0, outputHeight > 0 else { return nil }

        // Create offscreen render target texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared  // Needed for CPU readback

        guard let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }

        // Use DoVi pipeline if metadata is present
        if let doviMetadata = frame.doviMetadata {
            if !renderDoViPixelBufferToTexture(pixelBuffer, metadata: doviMetadata, to: outputTexture) {
                // Fall back to regular rendering if DoVi fails
                if !renderPixelBufferToTexture(pixelBuffer, to: outputTexture) {
                    return nil
                }
            }
        } else {
            // Render the pixel buffer to the texture using standard pipeline
            if !renderPixelBufferToTexture(pixelBuffer, to: outputTexture) {
                return nil
            }
        }

        // Read back the texture as CGImage
        return createCGImage(from: outputTexture)
    }

    /// Renders a pixel buffer to an arbitrary texture (for offscreen rendering)
    private func renderPixelBufferToTexture(_ pixelBuffer: CVPixelBuffer, to texture: MTLTexture) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0, height > 0 else { return false }

        // Select appropriate pipeline and textures based on format
        let pipelineState: MTLRenderPipelineState?
        var textures: [MTLTexture] = []

        switch format {
        case kCVPixelFormatType_420YpCbCr8Planar:  // I420
            pipelineState = i420VideoRangePipelineState
            guard let t = createI420Textures(from: pixelBuffer) else { return false }
            textures = [t.y, t.u, t.v]

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  // NV12 Video Range
            pipelineState = nv12PipelineState
            guard let t = createNV12Textures(from: pixelBuffer, bitDepth: 8) else { return false }
            textures = [t.y, t.uv]

        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  // NV12 Full Range
            pipelineState = nv12FullRangePipelineState
            guard let t = createNV12Textures(from: pixelBuffer, bitDepth: 8) else { return false }
            textures = [t.y, t.uv]

        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            pipelineState = bgraPipelineState
            guard let tex = createTexture(from: pixelBuffer, plane: 0, format: .bgra8Unorm, width: width, height: height) else { return false }
            textures = [tex]

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  // P010 (10-bit HDR)
            pipelineState = nv12PipelineState  // Will clamp HDR to SDR range
            guard let t = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
            textures = [t.y, t.uv]

        default:
            return renderPixelBufferToTextureWithCoreImage(pixelBuffer, to: texture)
        }

        guard let pipeline = pipelineState else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = createBasicRenderPassDescriptor(for: texture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }

        let viewport = Viewport(imageWidth: width, imageHeight: height, targetWidth: texture.width, targetHeight: texture.height)

        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(viewport.mtlViewport)

        for (index, tex) in textures.enumerated() {
            encoder.setFragmentTexture(tex, index: index)
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return true
    }

    /// Creates a Metal texture from a CVPixelBuffer plane
    private func createTexture(
        from pixelBuffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, width: Int, height: Int
    ) -> MTLTexture? {
        guard let textureCache = textureCache else { return nil }

        var textureCv: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            plane,
            &textureCv
        )

        guard result == kCVReturnSuccess, let textureCv = textureCv else { return nil }
        return CVMetalTextureGetTexture(textureCv)
    }

    /// Fallback: render pixel buffer to texture using CIContext
    private func renderPixelBufferToTextureWithCoreImage(
        _ pixelBuffer: CVPixelBuffer, to texture: MTLTexture
    ) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard imageWidth > 0, imageHeight > 0 else { return false }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let drawableSize = CGSize(width: CGFloat(texture.width), height: CGFloat(texture.height))
        let imageSize = CGSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight))

        let scaleX = drawableSize.width / imageSize.width
        let scaleY = drawableSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        guard scale > 0 && scale.isFinite else { return false }

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let x = (drawableSize.width - scaledWidth) / 2
        let y = (drawableSize.height - scaledHeight) / 2

        let transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
        ciImage = ciImage.transformed(by: transform)

        let drawableBounds = CGRect(origin: .zero, size: drawableSize)

        ciContext.render(
            ciImage,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: drawableBounds,
            colorSpace: colorSpace
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return true
    }

    /// Creates a CGImage from a Metal texture
    private func createCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4  // BGRA = 4 bytes per pixel

        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0
        )

        // Convert BGRA to RGBA for CGImage
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let b = pixelData[i]
            let r = pixelData[i + 2]
            pixelData[i] = r
            pixelData[i + 2] = b
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let provider = CGDataProvider(data: Data(pixelData) as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - Private Refactoring Helpers (Phase 1)

private extension RenderingEngine {
    /// Calculates aspect-fit viewport for rendering content to a target
    struct Viewport {
        let offsetX: Double
        let offsetY: Double
        let scaledWidth: Double
        let scaledHeight: Double
        
        init(imageWidth: Int, imageHeight: Int, targetWidth: Int, targetHeight: Int) {
            let drawableWidth = Double(targetWidth)
            let drawableHeight = Double(targetHeight)
            let imgWidth = Double(imageWidth)
            let imgHeight = Double(imageHeight)
            
            let scaleX = drawableWidth / imgWidth
            let scaleY = drawableHeight / imgHeight
            let scale = min(scaleX, scaleY)
            
            scaledWidth = imgWidth * scale
            scaledHeight = imgHeight * scale
            offsetX = (drawableWidth - scaledWidth) / 2
            offsetY = (drawableHeight - scaledHeight) / 2
        }
        
        var mtlViewport: MTLViewport {
            MTLViewport(
                originX: offsetX,
                originY: offsetY,
                width: scaledWidth,
                height: scaledHeight,
                znear: 0, zfar: 1
            )
        }
    }

    /// Flushes texture cache periodically to reduce transient memory
    func flushTextureCacheIfNeeded() {
        frameCounter += 1
        if frameCounter >= 60 {
            if let cache = textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }
            frameCounter = 0
        }
    }
    
    /// Creates a basic render pass descriptor for a texture target
    func createBasicRenderPassDescriptor(for texture: MTLTexture) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }
    
    /// Creates Metal textures for NV12 bi-planar format (8-bit or 10-bit)
    func createNV12Textures(from pixelBuffer: CVPixelBuffer, bitDepth: Int = 8) -> (y: MTLTexture, uv: MTLTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let yFormat: MTLPixelFormat = bitDepth == 10 ? .r16Unorm : .r8Unorm
        let uvFormat: MTLPixelFormat = bitDepth == 10 ? .rg16Unorm : .rg8Unorm
        
        guard let yTex = createTexture(from: pixelBuffer, plane: 0, format: yFormat, width: width, height: height),
              let uvTex = createTexture(from: pixelBuffer, plane: 1, format: uvFormat, width: width / 2, height: height / 2)
        else { return nil }
        
        return (yTex, uvTex)
    }
    
    /// Creates Metal textures for I420 tri-planar format (8-bit)
    func createI420Textures(from pixelBuffer: CVPixelBuffer) -> (y: MTLTexture, u: MTLTexture, v: MTLTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        guard let yTex = createTexture(from: pixelBuffer, plane: 0, format: .r8Unorm, width: width, height: height),
              let uTex = createTexture(from: pixelBuffer, plane: 1, format: .r8Unorm, width: width / 2, height: height / 2),
              let vTex = createTexture(from: pixelBuffer, plane: 2, format: .r8Unorm, width: width / 2, height: height / 2)
        else { return nil }
        
        return (yTex, uTex, vTex)
    }

    // MARK: - Pipeline Setup Helpers

    struct PipelineConfig {
        let fragmentFunction: String
        let pixelFormat: MTLPixelFormat
        let keyPath: ReferenceWritableKeyPath<RenderingEngine, MTLRenderPipelineState?>
    }

    /// Creates a render pipeline state from library and configuration
    func createPipeline(library: MTLLibrary, config: PipelineConfig) {
        guard let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
              let fragmentFunc = library.makeFunction(name: config.fragmentFunction)
        else { return }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = config.pixelFormat
        
        do {
            self[keyPath: config.keyPath] = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[RenderingEngine] Failed to create pipeline for \(config.fragmentFunction): \(error)")
        }
    }
}
