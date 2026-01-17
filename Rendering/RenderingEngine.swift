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
import AppKit

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
    /// The Metal device used for rendering.
    public let device: MTLDevice
    /// The command queue for submitting render commands.
    public let commandQueue: MTLCommandQueue
    /// A Core Image context for fallback rendering of unusual formats.
    public let ciContext: CIContext
    private var textureCache: CVMetalTextureCache?
    private var frameCounter: Int = 0

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
    
    // Dolby Vision Profile 5 pipeline (IPTPQc2 processing)
    private var doviNV12PipelineState: MTLRenderPipelineState?

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
        guard
            let library = try? device.makeDefaultLibrary(bundle: Bundle(for: RenderingEngine.self))
        else {
            print("[RenderingEngine] Failed to load Metal library from framework bundle")
            return
        }

        // NV12 pipeline - Video Range (bi-planar YUV, 16-235)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "nv12FragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                nv12PipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create NV12 video range pipeline: \(error)")
            }
        }

        // NV12 pipeline - Full Range (bi-planar YUV, 0-255)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "nv12FullRangeFragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                nv12FullRangePipelineState = try device.makeRenderPipelineState(
                    descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create NV12 full range pipeline: \(error)")
            }
        }

        // I420/YUV420P pipeline - Video Range (tri-planar YUV, 16-235)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "i420FragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                i420VideoRangePipelineState = try device.makeRenderPipelineState(
                    descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create I420 video range pipeline: \(error)")
            }
        }

        // I420/YUV420P pipeline - Full Range (tri-planar YUV, 0-255)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "i420FullRangeFragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                i420FullRangePipelineState = try device.makeRenderPipelineState(
                    descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create I420 full range pipeline: \(error)")
            }
        }

        // BGRA pipeline
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "bgraFragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                bgraPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create BGRA pipeline: \(error)")
            }
        }

        // HDR NV12/P010 pipeline (10-bit bi-planar, EDR output)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "hdrNV12FragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float  // EDR output

            do {
                hdrNV12PipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create HDR NV12 pipeline: \(error)")
            }
        }

        // HDR I420 pipeline (10-bit tri-planar, EDR output)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "hdrI420FragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float  // EDR output

            do {
                hdrI420PipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create HDR I420 pipeline: \(error)")
            }
        }

        // SDR NV12 pipeline with rgba16Float output (for HDR-configured layers)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "nv12FragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float

            do {
                nv12Float16PipelineState = try device.makeRenderPipelineState(
                    descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create NV12 Float16 pipeline: \(error)")
            }
        }

        // SDR I420 pipeline with rgba16Float output (for HDR-configured layers)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "i420FragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float

            do {
                i420Float16PipelineState = try device.makeRenderPipelineState(
                    descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create I420 Float16 pipeline: \(error)")
            }
        }
        
        // Dolby Vision Profile 5 NV12/P010 pipeline (IPTPQc2 processing)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
            let fragmentFunc = library.makeFunction(name: "doviNV12FragmentShader")
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float  // EDR output
            
            do {
                doviNV12PipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create DoVi NV12 pipeline: \(error)")
            }
        }
    }

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

    /// GPU-accelerated NV12 rendering using Metal shader
    /// - Parameter fullRange: If true, uses full range (0-255) conversion; otherwise video range (16-235)
    private func renderNV12PixelBuffer(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable, fullRange: Bool
    ) -> Bool {
        let pipelineState = fullRange ? nv12FullRangePipelineState : nv12PipelineState
        guard let pipelineState = pipelineState,
            let textureCache = textureCache
        else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0 && height > 0 else { return false }

        // Create Y texture (plane 0, r8Unorm)
        var yTextureCv: CVMetalTexture?
        var result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,  // Y plane
            &yTextureCv
        )
        guard result == kCVReturnSuccess, let yTextureCv = yTextureCv,
            let yTexture = CVMetalTextureGetTexture(yTextureCv)
        else {
            return false
        }

        // Create UV texture (plane 1, rg8Unorm, half resolution)
        var uvTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            width / 2,
            height / 2,
            1,  // UV plane
            &uvTextureCv
        )
        guard result == kCVReturnSuccess, let uvTextureCv = uvTextureCv,
            let uvTexture = CVMetalTextureGetTexture(uvTextureCv)
        else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return false
        }

        // Calculate viewport for aspect-fit scaling
        let drawableWidth = Float(drawable.texture.width)
        let drawableHeight = Float(drawable.texture.height)
        let imageWidth = Float(width)
        let imageHeight = Float(height)

        let scaleX = drawableWidth / imageWidth
        let scaleY = drawableHeight / imageHeight
        let scale = min(scaleX, scaleY)

        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(
            MTLViewport(
                originX: Double(offsetX),
                originY: Double(offsetY),
                width: Double(scaledWidth),
                height: Double(scaledHeight),
                znear: 0,
                zfar: 1
            ))
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Periodic cache flush to reduce transient texture memory
        frameCounter += 1
        if frameCounter >= 60 {
            CVMetalTextureCacheFlush(textureCache, 0)
            frameCounter = 0
        }

        return true
    }

    /// GPU-accelerated I420/YUV420P rendering using Metal shader
    /// This is the zero-copy path for software-decoded frames
    /// - Parameter fullRange: If true, uses full range (0-255) conversion; otherwise video range (16-235)
    private func renderI420PixelBuffer(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable, fullRange: Bool
    ) -> Bool {
        let pipelineState = fullRange ? i420FullRangePipelineState : i420VideoRangePipelineState
        guard let pipelineState = pipelineState,
            let textureCache = textureCache
        else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0 && height > 0 else { return false }

        // Create Y texture (plane 0, full resolution)
        var yTextureCv: CVMetalTexture?
        var result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,  // Y plane
            &yTextureCv
        )
        guard result == kCVReturnSuccess, let yTextureCv = yTextureCv,
            let yTexture = CVMetalTextureGetTexture(yTextureCv)
        else {
            return false
        }

        // Create U texture (plane 1, half resolution)
        var uTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width / 2,
            height / 2,
            1,  // U plane
            &uTextureCv
        )
        guard result == kCVReturnSuccess, let uTextureCv = uTextureCv,
            let uTexture = CVMetalTextureGetTexture(uTextureCv)
        else {
            return false
        }

        // Create V texture (plane 2, half resolution)
        var vTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width / 2,
            height / 2,
            2,  // V plane
            &vTextureCv
        )
        guard result == kCVReturnSuccess, let vTextureCv = vTextureCv,
            let vTexture = CVMetalTextureGetTexture(vTextureCv)
        else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return false
        }

        // Calculate viewport for aspect-fit scaling
        let drawableWidth = Float(drawable.texture.width)
        let drawableHeight = Float(drawable.texture.height)
        let imageWidth = Float(width)
        let imageHeight = Float(height)

        let scaleX = drawableWidth / imageWidth
        let scaleY = drawableHeight / imageHeight
        let scale = min(scaleX, scaleY)

        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(
            MTLViewport(
                originX: Double(offsetX),
                originY: Double(offsetY),
                width: Double(scaledWidth),
                height: Double(scaledHeight),
                znear: 0,
                zfar: 1
            ))
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uTexture, index: 1)
        encoder.setFragmentTexture(vTexture, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Periodic cache flush to reduce transient texture memory
        frameCounter += 1
        if frameCounter >= 60 {
            CVMetalTextureCacheFlush(textureCache, 0)
            frameCounter = 0
        }

        return true
    }

    /// GPU-accelerated BGRA rendering using Metal shader
    /// Eliminates Core Image overhead for BGRA pixel buffers
    private func renderBGRAPixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable)
        -> Bool
    {
        guard let pipelineState = bgraPipelineState,
            let textureCache = textureCache
        else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0 && height > 0 else { return false }

        // Create BGRA texture from pixel buffer
        var textureCv: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &textureCv
        )
        guard result == kCVReturnSuccess, let textureCv = textureCv,
            let texture = CVMetalTextureGetTexture(textureCv)
        else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return false
        }

        // Calculate viewport for aspect-fit scaling
        let drawableWidth = Float(drawable.texture.width)
        let drawableHeight = Float(drawable.texture.height)
        let imageWidth = Float(width)
        let imageHeight = Float(height)

        let scaleX = drawableWidth / imageWidth
        let scaleY = drawableHeight / imageHeight
        let scale = min(scaleX, scaleY)

        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(
            MTLViewport(
                originX: Double(offsetX),
                originY: Double(offsetY),
                width: Double(scaledWidth),
                height: Double(scaledHeight),
                znear: 0,
                zfar: 1
            ))
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // Periodic cache flush to reduce transient texture memory
        frameCounter += 1
        if frameCounter >= 60 {
            CVMetalTextureCacheFlush(textureCache, 0)
            frameCounter = 0
        }

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
                if renderDoViPixelBuffer(frame.pixelBuffer, metadata: doviMetadata, to: drawable) {
                    return
                }
                // Fall through to regular HDR if DoVi render failed
            } else {
                // Log warning once about layer configuration
                struct WarnState { static var warned = false }
                if !WarnState.warned {
                    print("[RenderingEngine] ⚠️ DoVi content detected but layer is BGRA8. Configure layer for EDR: pixelFormat = .rgba16Float, wantsExtendedDynamicRangeContent = true")
                    WarnState.warned = true
                }
            }
        }

        if isEffectivelyHDR {
            // Try HDR render path for 10-bit content IF the layer is configured for it
            if isFloat16Layer {
                if renderHDRPixelBuffer(frame.pixelBuffer, to: drawable) {
                    return
                }
            }

            // If HDR render failed or layer not ready, check if we need Float16 sdr fallback
            if isFloat16Layer {
                renderPixelBufferFloat16(frame.pixelBuffer, to: drawable)
                return
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

    /// Configuration for HDR Tone Mapping (BT.2390)
    public struct ToneMappingParams {
        var inputMin: Float = 0.0
        var inputMax: Float = 1000.0
        var outputMin: Float = 0.0
        var outputMax: Float = 1000.0
    }

    /// Target peak brightness of the display in nits.
    /// Default is 1000.0 (typical for Apple XDR displays).
    /// Adjust this based on the actual screen capabilities (e.g. 400 for standard SDR/HDR screens).
    public var targetDisplayPeakNits: Float = 1000.0

    /// Source content peak brightness in nits.
    /// Default is 1000.0 (standard HDR10).
    public var contentPeakNits: Float = 1000.0

    /// GPU-accelerated 10-bit P010 (HDR NV12) rendering with PQ->Linear conversion for EDR
    private func renderHDRNV12PixelBuffer(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = hdrNV12PipelineState,
            let textureCache = textureCache
        else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0 && height > 0 else { return false }

        // Create Y texture (plane 0, r16Unorm for 10-bit)
        var yTextureCv: CVMetalTexture?
        var result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r16Unorm,  // 10-bit needs 16-bit texture
            width,
            height,
            0,  // Y plane
            &yTextureCv
        )
        guard result == kCVReturnSuccess, let yTextureCv = yTextureCv,
            let yTexture = CVMetalTextureGetTexture(yTextureCv)
        else {
            return false
        }

        // Create UV texture (plane 1, rg16Unorm for 10-bit, half resolution)
        var uvTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg16Unorm,  // 10-bit needs 16-bit texture
            width / 2,
            height / 2,
            1,  // UV plane
            &uvTextureCv
        )
        guard result == kCVReturnSuccess, let uvTextureCv = uvTextureCv,
            let uvTexture = CVMetalTextureGetTexture(uvTextureCv)
        else {
            return false
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return false
        }

        // Calculate viewport for aspect-fit scaling
        let drawableWidth = Float(drawable.texture.width)
        let drawableHeight = Float(drawable.texture.height)
        let imageWidth = Float(width)
        let imageHeight = Float(height)

        let scaleX = drawableWidth / imageWidth
        let scaleY = drawableHeight / imageHeight
        let scale = min(scaleX, scaleY)

        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(
            MTLViewport(
                originX: Double(offsetX),
                originY: Double(offsetY),
                width: Double(scaledWidth),
                height: Double(scaledHeight),
                znear: 0,
                zfar: 1
            ))
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)

        // Calculate dynamic peak brightness
        // Current macOS EDR head room can change based on brightness slider and ambient light
        let currentDisplayPeak = getCurrentScreenPeakNits()

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
    
    // MARK: - Dolby Vision Profile 5 Rendering
    
    /// Metal buffer structs matching shader definitions (DoViReshapeComponent, DoViParams)
    /// Must match VideoShaders.metal layout exactly
    /// Metal struct: float pivots[9], float4 coeffs[8], float4 mmr[48], uint numPivots, float _padding[3]
    /// Total size: 36 + 128 + 768 + 4 + 12 = 948 bytes (aligned to 960)
    
    private struct DoViReshapeComponentBuffer {
        // float pivots[9] - 36 bytes
        var pivot0: Float = 0
        var pivot1: Float = 0
        var pivot2: Float = 0
        var pivot3: Float = 0
        var pivot4: Float = 0
        var pivot5: Float = 0
        var pivot6: Float = 0
        var pivot7: Float = 0
        var pivot8: Float = 0
        
        // float4 coeffs[8] - 128 bytes
        var coeff0: SIMD4<Float> = .zero
        var coeff1: SIMD4<Float> = .zero
        var coeff2: SIMD4<Float> = .zero
        var coeff3: SIMD4<Float> = .zero
        var coeff4: SIMD4<Float> = .zero
        var coeff5: SIMD4<Float> = .zero
        var coeff6: SIMD4<Float> = .zero
        var coeff7: SIMD4<Float> = .zero
        
        // float4 mmr[48] - 768 bytes (all 48 as separate properties)
        var mmr0: SIMD4<Float> = .zero
        var mmr1: SIMD4<Float> = .zero
        var mmr2: SIMD4<Float> = .zero
        var mmr3: SIMD4<Float> = .zero
        var mmr4: SIMD4<Float> = .zero
        var mmr5: SIMD4<Float> = .zero
        var mmr6: SIMD4<Float> = .zero
        var mmr7: SIMD4<Float> = .zero
        var mmr8: SIMD4<Float> = .zero
        var mmr9: SIMD4<Float> = .zero
        var mmr10: SIMD4<Float> = .zero
        var mmr11: SIMD4<Float> = .zero
        var mmr12: SIMD4<Float> = .zero
        var mmr13: SIMD4<Float> = .zero
        var mmr14: SIMD4<Float> = .zero
        var mmr15: SIMD4<Float> = .zero
        var mmr16: SIMD4<Float> = .zero
        var mmr17: SIMD4<Float> = .zero
        var mmr18: SIMD4<Float> = .zero
        var mmr19: SIMD4<Float> = .zero
        var mmr20: SIMD4<Float> = .zero
        var mmr21: SIMD4<Float> = .zero
        var mmr22: SIMD4<Float> = .zero
        var mmr23: SIMD4<Float> = .zero
        var mmr24: SIMD4<Float> = .zero
        var mmr25: SIMD4<Float> = .zero
        var mmr26: SIMD4<Float> = .zero
        var mmr27: SIMD4<Float> = .zero
        var mmr28: SIMD4<Float> = .zero
        var mmr29: SIMD4<Float> = .zero
        var mmr30: SIMD4<Float> = .zero
        var mmr31: SIMD4<Float> = .zero
        var mmr32: SIMD4<Float> = .zero
        var mmr33: SIMD4<Float> = .zero
        var mmr34: SIMD4<Float> = .zero
        var mmr35: SIMD4<Float> = .zero
        var mmr36: SIMD4<Float> = .zero
        var mmr37: SIMD4<Float> = .zero
        var mmr38: SIMD4<Float> = .zero
        var mmr39: SIMD4<Float> = .zero
        var mmr40: SIMD4<Float> = .zero
        var mmr41: SIMD4<Float> = .zero
        var mmr42: SIMD4<Float> = .zero
        var mmr43: SIMD4<Float> = .zero
        var mmr44: SIMD4<Float> = .zero
        var mmr45: SIMD4<Float> = .zero
        var mmr46: SIMD4<Float> = .zero
        var mmr47: SIMD4<Float> = .zero
        
        // uint numPivots + float _padding[3] - 16 bytes
        var numPivots: UInt32 = 0
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
        
        init(from data: DoViReshapeData) {
            numPivots = UInt32(data.numPivots)
            
            // Copy pivots
            pivot0 = data.pivots[0]
            pivot1 = data.pivots[1]
            pivot2 = data.pivots[2]
            pivot3 = data.pivots[3]
            pivot4 = data.pivots[4]
            pivot5 = data.pivots[5]
            pivot6 = data.pivots[6]
            pivot7 = data.pivots[7]
            pivot8 = data.pivots[8]
            
            // Pack coefficients: polynomial or MMR based on method
            var mmrIdx = 0
            for i in 0..<8 {
                let method = data.method[i]
                if method == .polynomial {
                    let poly = data.polyCoeffs[i]
                    let c = SIMD4<Float>(poly[0], poly[1], poly[2], 0)
                    setCoeff(i, c)
                } else {
                    let order = Int(data.mmrOrder[i])
                    let c = SIMD4<Float>(data.mmrConstant[i], Float(mmrIdx), 0, Float(order))
                    setCoeff(i, c)
                    
                    for j in 0..<order {
                        let coeffs = data.mmrCoeffs[i][j]
                        setMMR(mmrIdx, SIMD4<Float>(coeffs[0], coeffs[1], coeffs[2], 0))
                        setMMR(mmrIdx + 1, SIMD4<Float>(coeffs[3], coeffs[4], coeffs[5], coeffs[6]))
                        mmrIdx += 2
                    }
                }
            }
        }
        
        mutating func setCoeff(_ i: Int, _ v: SIMD4<Float>) {
            switch i {
            case 0: coeff0 = v; case 1: coeff1 = v; case 2: coeff2 = v; case 3: coeff3 = v
            case 4: coeff4 = v; case 5: coeff5 = v; case 6: coeff6 = v; case 7: coeff7 = v
            default: break
            }
        }
        
        mutating func setMMR(_ i: Int, _ v: SIMD4<Float>) {
            switch i {
            case 0: mmr0 = v; case 1: mmr1 = v; case 2: mmr2 = v; case 3: mmr3 = v
            case 4: mmr4 = v; case 5: mmr5 = v; case 6: mmr6 = v; case 7: mmr7 = v
            case 8: mmr8 = v; case 9: mmr9 = v; case 10: mmr10 = v; case 11: mmr11 = v
            case 12: mmr12 = v; case 13: mmr13 = v; case 14: mmr14 = v; case 15: mmr15 = v
            case 16: mmr16 = v; case 17: mmr17 = v; case 18: mmr18 = v; case 19: mmr19 = v
            case 20: mmr20 = v; case 21: mmr21 = v; case 22: mmr22 = v; case 23: mmr23 = v
            case 24: mmr24 = v; case 25: mmr25 = v; case 26: mmr26 = v; case 27: mmr27 = v
            case 28: mmr28 = v; case 29: mmr29 = v; case 30: mmr30 = v; case 31: mmr31 = v
            case 32: mmr32 = v; case 33: mmr33 = v; case 34: mmr34 = v; case 35: mmr35 = v
            case 36: mmr36 = v; case 37: mmr37 = v; case 38: mmr38 = v; case 39: mmr39 = v
            case 40: mmr40 = v; case 41: mmr41 = v; case 42: mmr42 = v; case 43: mmr43 = v
            case 44: mmr44 = v; case 45: mmr45 = v; case 46: mmr46 = v; case 47: mmr47 = v
            default: break
            }
        }
    }
    
    /// Metal struct layout for DoViParams:
    /// float3 (16 bytes aligned), float3x3 (48 bytes), float3x3 (48 bytes), float, float, float _padding[2]
    /// Total: 16 + 48 + 48 + 4 + 4 + 8 = 128 bytes
    private struct DoViParamsBuffer {
        // float3 in Metal is 16-byte aligned, use float4 for compatibility
        var nonlinearOffset: SIMD4<Float>  // Using float4 since Metal's float3 is 16-byte aligned
        var nonlinearMatrix: matrix_float3x3
        var lms2rgbMatrix: matrix_float3x3
        var sourceMinPQ: Float
        var sourceMaxPQ: Float
        var pad0: Float = 0
        var pad1: Float = 0
        
        init(from metadata: DoViMetadata) {
            // Pack float3 into float4 (Metal's float3 alignment)
            let offset = metadata.nonlinearOffset
            nonlinearOffset = SIMD4<Float>(offset.x, offset.y, offset.z, 0)
            nonlinearMatrix = metadata.nonlinearMatrix
            
            // Combine HPE LMS→RGB inverse with rgb_to_lms from metadata
            // Matrix is row-major, so we specify rows here
            // Row 0: { 3.06441879, -2.16597676, 0.10155818}
            // Row 1: {-0.65612108, 1.78554118, -0.12943749}
            // Row 2: { 0.01736321, -0.04725154, 1.03004253}
            // Swift matrix_float3x3(columns:) takes columns, so we transpose
            let hpeLms2Rgb = matrix_float3x3(columns: (
                SIMD3<Float>(3.06441879, -0.65612108, 0.01736321),   // Column 0 = row values at col 0
                SIMD3<Float>(-2.16597676, 1.78554118, -0.04725154), // Column 1 = row values at col 1  
                SIMD3<Float>(0.10155818, -0.12943749, 1.03004253)   // Column 2 = row values at col 2
            ))
            // lms2rgb = hpeLms2Rgb * metadata.linear
            // Note: matrix multiplication order matters - test both orders
            lms2rgbMatrix = hpeLms2Rgb * metadata.linearMatrix
            
            sourceMinPQ = metadata.sourceMinPQ
            sourceMaxPQ = metadata.sourceMaxPQ
        }
    }
    
    /// Renders Dolby Vision Profile 5 (IPTPQc2) content with reshape processing
    private func renderDoViPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        metadata: DoViMetadata,
        to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = doviNV12PipelineState,
              let textureCache = textureCache
        else {
            print("[RenderingEngine] DoVi pipeline not available")
            return false
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }
        
        // Create Y texture (plane 0, r16Unorm for 10-bit)
        var yTextureCv: CVMetalTexture?
        var result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r16Unorm,
            width,
            height,
            0,
            &yTextureCv
        )
        guard result == kCVReturnSuccess, let yTextureCv = yTextureCv,
              let yTexture = CVMetalTextureGetTexture(yTextureCv)
        else {
            return false
        }
        
        // Create UV texture (plane 1, rg16Unorm for 10-bit)
        var uvTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg16Unorm,
            width / 2,
            height / 2,
            1,
            &uvTextureCv
        )
        guard result == kCVReturnSuccess, let uvTextureCv = uvTextureCv,
              let uvTexture = CVMetalTextureGetTexture(uvTextureCv)
        else {
            return false
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        
        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return false
        }
        
        // Calculate viewport for aspect-fit scaling
        let drawableWidth = Float(drawable.texture.width)
        let drawableHeight = Float(drawable.texture.height)
        let imageWidth = Float(width)
        let imageHeight = Float(height)
        
        let scaleX = drawableWidth / imageWidth
        let scaleY = drawableHeight / imageHeight
        let scale = min(scaleX, scaleY)
        
        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(MTLViewport(
            originX: Double(offsetX),
            originY: Double(offsetY),
            width: Double(scaledWidth),
            height: Double(scaledHeight),
            znear: 0, zfar: 1
        ))
        
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        
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
        
        // Encode tone mapping params (buffer 4)
        // Use L1 scene brightness if available, otherwise fall back to static metadata
        let currentDisplayPeak = getCurrentScreenPeakNits()
        let dynamicPeakPQ = metadata.sceneMaxPQ ?? metadata.sourceMaxPQ
        let dynamicPeakNits = pqToNits(dynamicPeakPQ)
        
        // Log L1 usage once for verification
        struct L1LogState { static var logged = false }
        if !L1LogState.logged, metadata.sceneMaxPQ != nil {
            print("[RenderingEngine] Using L1 scene brightness: max=\(dynamicPeakPQ), nits=\(dynamicPeakNits)")
            L1LogState.logged = true
        }
        
        var toneParams = ToneMappingParams(
            inputMin: 0.0,
            inputMax: dynamicPeakNits,
            outputMin: 0.0,
            outputMax: currentDisplayPeak
        )
        encoder.setFragmentBytes(&toneParams, length: MemoryLayout<ToneMappingParams>.size, index: 4)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        return true
    }
    
    /// Converts PQ value (0.0-1.0) to absolute luminance in nits
    private func pqToNits(_ pq: Float) -> Float {
        guard pq > 0 else { return 0 }
        let m1: Float = 0.1593017578125
        let m2: Float = 78.84375
        let c1: Float = 0.8359375
        let c2: Float = 18.8515625
        let c3: Float = 18.6875
        
        let p = pow(pq, 1.0 / m2)
        let num = max(p - c1, 0)
        let den = c2 - c3 * p
        return pow(num / max(den, 1e-6), 1.0 / m1) * 10000.0
    }

    /// Detects the maximum potential brightness of the current screen in nits.
    /// Returns 100.0 (SDR) if EDR is unavailable or normalizes to standard reference.
    private func getCurrentScreenPeakNits() -> Float {
        // Find the screen containing the window, or default to main
        // Since we don't have direct access to the NSWindow from the engine easily without passing it down,
        // we'll use a heuristic: NSScreen.main (screen with key window) or the first deep screen.
        
        guard let screen = NSScreen.main else { return 100.0 }
        
        // maximumPotentialExtendedDynamicRangeColorComponentValue
        // 1.0 = SDR white (100 nits).
        // e.g. 16.0 = 1600 nits.
        let scalingFactor = Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        
        // Clamp to reasonable limits just in case
        return max(100.0, scalingFactor * 100.0)
    }

    /// NV12 rendering to rgba16Float target (for HDR-configured layers with SDR content)
    private func renderNV12PixelBufferFloat16(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = nv12Float16PipelineState,
            let textureCache = textureCache
        else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0 && height > 0 else { return false }

        // Create Y texture
        var yTextureCv: CVMetalTexture?
        var result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &yTextureCv
        )
        guard result == kCVReturnSuccess, let yTextureCv = yTextureCv,
            let yTexture = CVMetalTextureGetTexture(yTextureCv)
        else { return false }

        // Create UV texture
        var uvTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &uvTextureCv
        )
        guard result == kCVReturnSuccess, let uvTextureCv = uvTextureCv,
            let uvTexture = CVMetalTextureGetTexture(uvTextureCv)
        else { return false }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return false }

        let drawableWidth = Float(drawable.texture.width)
        let drawableHeight = Float(drawable.texture.height)
        let scaleX = drawableWidth / Float(width)
        let scaleY = drawableHeight / Float(height)
        let scale = min(scaleX, scaleY)
        let scaledWidth = Float(width) * scale
        let scaledHeight = Float(height) * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(
            MTLViewport(
                originX: Double(offsetX), originY: Double(offsetY),
                width: Double(scaledWidth), height: Double(scaledHeight), znear: 0, zfar: 1))
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
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
        guard let pipelineState = i420Float16PipelineState,
            let textureCache = textureCache
        else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0 && height > 0 else { return false }

        // Create Y, U, V textures
        var yTextureCv: CVMetalTexture?
        var result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &yTextureCv
        )
        guard result == kCVReturnSuccess, let yTextureCv = yTextureCv,
            let yTexture = CVMetalTextureGetTexture(yTextureCv)
        else { return false }

        var uTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, width / 2, height / 2, 1, &uTextureCv
        )
        guard result == kCVReturnSuccess, let uTextureCv = uTextureCv,
            let uTexture = CVMetalTextureGetTexture(uTextureCv)
        else { return false }

        var vTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, width / 2, height / 2, 2, &vTextureCv
        )
        guard result == kCVReturnSuccess, let vTextureCv = vTextureCv,
            let vTexture = CVMetalTextureGetTexture(vTextureCv)
        else { return false }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return false }

        let drawableWidth = Float(drawable.texture.width)
        let drawableHeight = Float(drawable.texture.height)
        let scaleX = drawableWidth / Float(width)
        let scaleY = drawableHeight / Float(height)
        let scale = min(scaleX, scaleY)
        let scaledWidth = Float(width) * scale
        let scaledHeight = Float(height) * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2

        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(
            MTLViewport(
                originX: Double(offsetX), originY: Double(offsetY),
                width: Double(scaledWidth), height: Double(scaledHeight), znear: 0, zfar: 1))
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uTexture, index: 1)
        encoder.setFragmentTexture(vTexture, index: 2)
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

        // Render the pixel buffer to the texture
        if !renderPixelBufferToTexture(pixelBuffer, to: outputTexture) {
            return nil
        }

        // Read back the texture as CGImage
        return createCGImage(from: outputTexture)
    }

    /// Renders a pixel buffer to an arbitrary texture (for offscreen rendering)
    private func renderPixelBufferToTexture(_ pixelBuffer: CVPixelBuffer, to texture: MTLTexture)
        -> Bool
    {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width > 0, height > 0 else { return false }
        guard let textureCache = textureCache else { return false }

        // Select appropriate pipeline based on format
        let pipelineState: MTLRenderPipelineState?
        var textures: [MTLTexture] = []

        switch format {
        case kCVPixelFormatType_420YpCbCr8Planar:  // I420
            pipelineState = i420VideoRangePipelineState
            guard
                let yTex = createTexture(
                    from: pixelBuffer, plane: 0, format: .r8Unorm, width: width, height: height),
                let uTex = createTexture(
                    from: pixelBuffer, plane: 1, format: .r8Unorm, width: width / 2,
                    height: height / 2),
                let vTex = createTexture(
                    from: pixelBuffer, plane: 2, format: .r8Unorm, width: width / 2,
                    height: height / 2)
            else { return false }
            textures = [yTex, uTex, vTex]

        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  // NV12 Video Range
            pipelineState = nv12PipelineState
            guard
                let yTex = createTexture(
                    from: pixelBuffer, plane: 0, format: .r8Unorm, width: width, height: height),
                let uvTex = createTexture(
                    from: pixelBuffer, plane: 1, format: .rg8Unorm, width: width / 2,
                    height: height / 2)
            else { return false }
            textures = [yTex, uvTex]

        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  // NV12 Full Range
            pipelineState = nv12FullRangePipelineState
            guard
                let yTex = createTexture(
                    from: pixelBuffer, plane: 0, format: .r8Unorm, width: width, height: height),
                let uvTex = createTexture(
                    from: pixelBuffer, plane: 1, format: .rg8Unorm, width: width / 2,
                    height: height / 2)
            else { return false }
            textures = [yTex, uvTex]

        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            pipelineState = bgraPipelineState
            guard
                let tex = createTexture(
                    from: pixelBuffer, plane: 0, format: .bgra8Unorm, width: width, height: height)
            else { return false }
            textures = [tex]

        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  // P010 (10-bit HDR)
            // For thumbnail generation, we use a special approach:
            // Create a BGRA8 pipeline that can accept the 16-bit textures but output 8-bit
            // We'll use the NV12 pipeline since the shader will clamp values appropriately
            pipelineState = nv12PipelineState  // Will clamp HDR to SDR range
            guard
                let yTex = createTexture(
                    from: pixelBuffer, plane: 0, format: .r16Unorm, width: width, height: height),
                let uvTex = createTexture(
                    from: pixelBuffer, plane: 1, format: .rg16Unorm, width: width / 2,
                    height: height / 2)
            else { return false }
            textures = [yTex, uvTex]

        default:
            // Fallback: try to use CIContext to convert
            return renderPixelBufferToTextureWithCoreImage(pixelBuffer, to: texture)
        }

        guard let pipeline = pipelineState else { return false }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }

        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return false
        }

        // Calculate aspect-fit viewport
        let drawableWidth = Float(texture.width)
        let drawableHeight = Float(texture.height)
        let imageWidth = Float(width)
        let imageHeight = Float(height)

        let scaleX = drawableWidth / imageWidth
        let scaleY = drawableHeight / imageHeight
        let scale = min(scaleX, scaleY)

        let scaledWidth = imageWidth * scale
        let scaledHeight = imageHeight * scale
        let offsetX = (drawableWidth - scaledWidth) / 2
        let offsetY = (drawableHeight - scaledHeight) / 2

        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(
            MTLViewport(
                originX: Double(offsetX),
                originY: Double(offsetY),
                width: Double(scaledWidth),
                height: Double(scaledHeight),
                znear: 0, zfar: 1
            ))

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
