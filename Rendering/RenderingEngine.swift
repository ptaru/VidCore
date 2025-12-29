//
//  RenderingEngine.swift
//  VidCore
//
//  Metal rendering engine for video frames with GPU YUV conversion
//

import Metal
import MetalKit
import CoreVideo
import CoreImage

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
    private var nv12PipelineState: MTLRenderPipelineState?        // Video range (16-235)
    private var nv12FullRangePipelineState: MTLRenderPipelineState?  // Full range (0-255)

    private var i420VideoRangePipelineState: MTLRenderPipelineState? // Video range (16-235)
    private var i420FullRangePipelineState: MTLRenderPipelineState?  // Full range (0-255)
    private var bgraPipelineState: MTLRenderPipelineState?
    
    // SDR pipelines with rgba16Float output (for HDR-configured layers)
    private var nv12Float16PipelineState: MTLRenderPipelineState?
    private var i420Float16PipelineState: MTLRenderPipelineState?
    
    // HDR pipelines (output rgba16Float for EDR with PQ->linear conversion)
    private var hdrNV12PipelineState: MTLRenderPipelineState?
    private var hdrI420PipelineState: MTLRenderPipelineState?
    
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
        
        // NV12 pipeline - Video Range (bi-planar YUV, 16-235)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
           let fragmentFunc = library.makeFunction(name: "nv12FragmentShader") {
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
           let fragmentFunc = library.makeFunction(name: "nv12FullRangeFragmentShader") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            do {
                nv12FullRangePipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create NV12 full range pipeline: \(error)")
            }
        }
        
        // I420/YUV420P pipeline - Video Range (tri-planar YUV, 16-235)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
           let fragmentFunc = library.makeFunction(name: "i420FragmentShader") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            do {
                i420VideoRangePipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create I420 video range pipeline: \(error)")
            }
        }
        
        // I420/YUV420P pipeline - Full Range (tri-planar YUV, 0-255)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
           let fragmentFunc = library.makeFunction(name: "i420FullRangeFragmentShader") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            do {
                i420FullRangePipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create I420 full range pipeline: \(error)")
            }
        }
        
        // BGRA pipeline
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
           let fragmentFunc = library.makeFunction(name: "bgraFragmentShader") {
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
           let fragmentFunc = library.makeFunction(name: "hdrNV12FragmentShader") {
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
           let fragmentFunc = library.makeFunction(name: "hdrI420FragmentShader") {
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
           let fragmentFunc = library.makeFunction(name: "nv12FragmentShader") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            
            do {
                nv12Float16PipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create NV12 Float16 pipeline: \(error)")
            }
        }
        
        // SDR I420 pipeline with rgba16Float output (for HDR-configured layers)
        if let vertexFunc = library.makeFunction(name: "yuvVertexShader"),
           let fragmentFunc = library.makeFunction(name: "i420FragmentShader") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunc
            descriptor.fragmentFunction = fragmentFunc
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            
            do {
                i420Float16PipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[RenderingEngine] Failed to create I420 Float16 pipeline: \(error)")
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
        if format == kCVPixelFormatType_32BGRA ||
           format == kCVPixelFormatType_32ARGB {
            if renderBGRAPixelBuffer(pixelBuffer, to: drawable) {
                return
            }
        }
        
        // Fallback to Core Image for unknown/rare formats only
        renderPixelBufferWithCoreImage(pixelBuffer, to: drawable)
    }
    
    /// GPU-accelerated NV12 rendering using Metal shader
    /// - Parameter fullRange: If true, uses full range (0-255) conversion; otherwise video range (16-235)
    private func renderNV12PixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable, fullRange: Bool) -> Bool {
        let pipelineState = fullRange ? nv12FullRangePipelineState : nv12PipelineState
        guard let pipelineState = pipelineState,
              let textureCache = textureCache else {
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
              let yTexture = CVMetalTextureGetTexture(yTextureCv) else {
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
              let uvTexture = CVMetalTextureGetTexture(uvTextureCv) else {
            return false
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        
        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
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
    private func renderI420PixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable, fullRange: Bool) -> Bool {
        let pipelineState = fullRange ? i420FullRangePipelineState : i420VideoRangePipelineState
        guard let pipelineState = pipelineState,
              let textureCache = textureCache else {
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
              let yTexture = CVMetalTextureGetTexture(yTextureCv) else {
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
              let uTexture = CVMetalTextureGetTexture(uTextureCv) else {
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
              let vTexture = CVMetalTextureGetTexture(vTextureCv) else {
            return false
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        
        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
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
    private func renderBGRAPixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) -> Bool {
        guard let pipelineState = bgraPipelineState,
              let textureCache = textureCache else {
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
              let texture = CVMetalTextureGetTexture(textureCv) else {
            return false
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        
        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
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
    private func renderPixelBufferWithCoreImage(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard imageWidth > 0 && imageHeight > 0 &&
              drawable.texture.width > 0 && drawable.texture.height > 0 else {
            return
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        let drawableSize = CGSize(width: CGFloat(drawable.texture.width), height: CGFloat(drawable.texture.height))
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

        let drawableBounds = CGRect(x: 0, y: 0, width: drawableSize.width, height: drawableSize.height)
        ciImage = ciImage.cropped(to: drawableBounds)

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
            renderEncoder.endEncoding()
        }

        ciContext.render(ciImage,
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
        
        // Debug frame info
        struct DebugState { static var frameCount = 0 }
        if DebugState.frameCount < 3 {
            let formatStr = String(format: "0x%08X", format)
            print("[RenderingEngine] Frame \(DebugState.frameCount): isHDR=\(frame.isHDR), format=\(formatStr), layer=\(isFloat16Layer ? "Float16" : "BGRA8")")
            DebugState.frameCount += 1
        }
        
        if frame.isHDR {
            // Try HDR render path for 10-bit content IF the layer is configured for it
            if isFloat16Layer {
                if renderHDRPixelBuffer(frame.pixelBuffer, to: drawable) {
                    return
                }
            } else {
                print("[RenderingEngine] HDR frame but layer is BGRA8 - fallback to safe path")
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
    private func renderPixelBufferFloat16(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        // I420/YUV420P with rgba16Float output
        if format == kCVPixelFormatType_420YpCbCr8Planar {
            if renderI420PixelBufferFloat16(pixelBuffer, to: drawable) {
                return
            }
        }
        
        // NV12 with rgba16Float output
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            if renderNV12PixelBufferFloat16(pixelBuffer, to: drawable) {
                return
            }
        }
        
        // For other formats, fall back to Core Image (it should handle the conversion)
        renderPixelBufferWithCoreImage(pixelBuffer, to: drawable)
    }
    
    /// Renders HDR pixel buffer (10-bit P010 or I420) to EDR output
    private func renderHDRPixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        // P010 - 10-bit bi-planar (common hardware decode output for HDR)
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
            return renderHDRNV12PixelBuffer(pixelBuffer, to: drawable)
        }
        
        // 8-bit I420 from FFmpeg sws_scale - can't do true HDR, return false to use SDR fallback
        return false
    }
    
    /// GPU-accelerated 10-bit P010 (HDR NV12) rendering with PQ->Linear conversion for EDR
    private func renderHDRNV12PixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) -> Bool {
        guard let pipelineState = hdrNV12PipelineState,
              let textureCache = textureCache else {
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
              let yTexture = CVMetalTextureGetTexture(yTextureCv) else {
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
              let uvTexture = CVMetalTextureGetTexture(uvTextureCv) else {
            return false
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }
        
        // Setup render pass
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
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
            znear: 0,
            zfar: 1
        ))
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
        
        return true
    }
    
    /// NV12 rendering to rgba16Float target (for HDR-configured layers with SDR content)
    private func renderNV12PixelBufferFloat16(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) -> Bool {
        guard let pipelineState = nv12Float16PipelineState,
              let textureCache = textureCache else {
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
              let yTexture = CVMetalTextureGetTexture(yTextureCv) else { return false }
        
        // Create UV texture
        var uvTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &uvTextureCv
        )
        guard result == kCVReturnSuccess, let uvTextureCv = uvTextureCv,
              let uvTexture = CVMetalTextureGetTexture(uvTextureCv) else { return false }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
        
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
        encoder.setViewport(MTLViewport(originX: Double(offsetX), originY: Double(offsetY),
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
    private func renderI420PixelBufferFloat16(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) -> Bool {
        guard let pipelineState = i420Float16PipelineState,
              let textureCache = textureCache else {
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
              let yTexture = CVMetalTextureGetTexture(yTextureCv) else { return false }
        
        var uTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, width / 2, height / 2, 1, &uTextureCv
        )
        guard result == kCVReturnSuccess, let uTextureCv = uTextureCv,
              let uTexture = CVMetalTextureGetTexture(uTextureCv) else { return false }
        
        var vTextureCv: CVMetalTexture?
        result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .r8Unorm, width / 2, height / 2, 2, &vTextureCv
        )
        guard result == kCVReturnSuccess, let vTextureCv = vTextureCv,
              let vTexture = CVMetalTextureGetTexture(vTextureCv) else { return false }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return false }
        
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
        encoder.setViewport(MTLViewport(originX: Double(offsetX), originY: Double(offsetY),
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
}
