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

    // MARK: - Debug Observable State
    public private(set) var currentDisplayPeakNits: Float = 0
    public private(set) var lastL1SceneMaxNits: Float?
    public private(set) var currentRenderMode: String = "Initializing"

    // SDR pipelines (bgra8Unorm)
    private var nv12PipelineState: MTLRenderPipelineState?
    private var nv12FullRangePipelineState: MTLRenderPipelineState?
    private var i420VideoRangePipelineState: MTLRenderPipelineState?
    private var i420FullRangePipelineState: MTLRenderPipelineState?
    private var bgraPipelineState: MTLRenderPipelineState?

    // SDR pipelines (rgba16Float)
    private var nv12Float16PipelineState: MTLRenderPipelineState?
    private var i420Float16PipelineState: MTLRenderPipelineState?

    // HDR pipelines (rgba16Float, PQ conversion)
    private var hdrNV12PipelineState: MTLRenderPipelineState?

    
    // DoVi Profile 5 (IPTPQc2)
    private var doviNV12PipelineState: MTLRenderPipelineState?

    // Generic Tone Mapping
    private var toneMapPipelineState: MTLRenderPipelineState?

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

        var cache: CVMetalTextureCache?
        let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard result == kCVReturnSuccess, let textureCache = cache else {
            return nil
        }
        self.textureCache = textureCache

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
            PipelineConfig(fragmentFunction: "nv12FragmentShader", pixelFormat: .rgba16Float, keyPath: \.nv12Float16PipelineState),
            PipelineConfig(fragmentFunction: "i420FragmentShader", pixelFormat: .rgba16Float, keyPath: \.i420Float16PipelineState),
            PipelineConfig(fragmentFunction: "doviNV12FragmentShader", pixelFormat: .rgba16Float, keyPath: \.doviNV12PipelineState),
            PipelineConfig(fragmentFunction: "toneMapSDRFragmentShader", pixelFormat: .bgra8Unorm, keyPath: \.toneMapPipelineState)
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

        // I420/YUV420P (tri-planar)
        if format == kCVPixelFormatType_420YpCbCr8Planar {
            if renderI420PixelBuffer(pixelBuffer, to: drawable, fullRange: false) {
                return
            }
        }

        // NV12 (bi-planar)
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

        // BGRA
        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            if renderBGRAPixelBuffer(pixelBuffer, to: drawable) {
                return
            }
        }

        // Core Image fallback
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
        
        currentRenderMode = fullRange ? "SDR NV12 (Full)" : "SDR NV12 (Video)"

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 8) else { return false }
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: drawable.texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: [textures.y, textures.uv]
        ) else { return false }

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
        
        currentRenderMode = fullRange ? "SDR I420 (Full)" : "SDR I420 (Video)"

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createI420Textures(from: pixelBuffer) else { return false }

        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: drawable.texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: [textures.y, textures.u, textures.v]
        ) else { return false }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        flushTextureCacheIfNeeded()
        return true
    }

    /// GPU-accelerated BGRA rendering using Metal shader
    /// Eliminates Core Image overhead for BGRA pixel buffers
    private func renderBGRAPixelBuffer(_ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) -> Bool {
        guard let pipelineState = bgraPipelineState else { return false }
        
        currentRenderMode = "SDR BGRA"

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let texture = createTexture(from: pixelBuffer, plane: 0, format: .bgra8Unorm, width: width, height: height) else { return false }
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: drawable.texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: [texture]
        ) else { return false }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        flushTextureCacheIfNeeded()
        return true
    }

    /// Renders a pixel buffer using Core Image (fallback path for rare formats)
    private func renderPixelBufferWithCoreImage(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) {
        currentRenderMode = "Core Image (Fallback)"
        
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
        
        // DoVi is effectively HDR
        let isEffectivelyHDR = frame.isHDR || hasDoVi



        // DoVi Profile 5 (IPTPQc2)
        if let doviMetadata = frame.doviMetadata {
            if isFloat16Layer {
                // EDR display
                currentRenderMode = "Dolby Vision"
                let peak = ToneMapping.getCurrentScreenPeakNits(for: drawable.layer)
                self.currentDisplayPeakNits = peak
                if let sceneMax = doviMetadata.sceneMaxPQ {
                    self.lastL1SceneMaxNits = ToneMapping.pqToNits(sceneMax)
                }
                
                if renderDoViToTexture(frame.pixelBuffer, metadata: doviMetadata, to: drawable.texture, targetPeakNits: peak) {
                    // Update state variables (moved out of helper)
                    if let commandBuffer = commandQueue.makeCommandBuffer() {
                        commandBuffer.present(drawable)
                        commandBuffer.commit()
                    }
                    return
                }
                // Fallback to HDR
            }
        }

        if isEffectivelyHDR {
            if isFloat16Layer {
                // EDR display
                let currentDisplayPeak = ToneMapping.getCurrentScreenPeakNits(for: drawable.layer)
                self.currentDisplayPeakNits = currentDisplayPeak
                self.currentRenderMode = "HDR10"
                
                if renderHDRToTexture(frame.pixelBuffer, to: drawable.texture, targetPeakNits: currentDisplayPeak) {
                    if let commandBuffer = commandQueue.makeCommandBuffer() {
                        commandBuffer.present(drawable)
                        commandBuffer.commit()
                    }
                    return
                }
                // Fallback to Float16 SDR
                renderPixelBufferFloat16(frame.pixelBuffer, to: drawable)
                return
            }
        }

        // SDR path
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

        // I420 (rgba16Float)
        if format == kCVPixelFormatType_420YpCbCr8Planar {
            if renderI420PixelBufferFloat16(pixelBuffer, to: drawable) {
                return
            }
        }

        // NV12 (rgba16Float)
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        {
            if renderNV12PixelBufferFloat16(pixelBuffer, to: drawable) {
                return
            }
        }

        // Fallback to Core Image
        renderPixelBufferWithCoreImage(pixelBuffer, to: drawable)
    }

    /// GPU-accelerated 10-bit P010 (HDR NV12) rendering with PQ->Linear conversion for EDR
    private func renderHDRToTexture(
        _ pixelBuffer: CVPixelBuffer, to texture: MTLTexture, targetPeakNits: Float
    ) -> Bool {
        guard let pipelineState = hdrNV12PipelineState else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
        
        // Tone mapping params
        var params = ToneMappingParams(
            inputMin: 0.0,
            inputMax: contentPeakNits,
            outputMin: 0.0,
            outputMax: targetPeakNits
        )
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: [textures.y, textures.uv],
            configureEncoder: { encoder in
                encoder.setFragmentBytes(&params, length: MemoryLayout<ToneMappingParams>.size, index: 0)
            }
        ) else { return false }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return true
    }

    /// Renders Dolby Vision Profile 5 (IPTPQc2) content with reshape processing
    private func renderDoViToTexture(
        _ pixelBuffer: CVPixelBuffer,
        metadata: DoViMetadata,
        to texture: MTLTexture,
        targetPeakNits: Float
    ) -> Bool {
        guard let pipelineState = doviNV12PipelineState else {
            // print("[RenderingEngine] DoVi pipeline not available")
            return false
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }
        
        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
        
        // DoVi parameters
        var doviParams = DoViParamsBuffer(from: metadata)
        
        // Reshape components (buffers 1-3)
        var compI = DoViReshapeComponentBuffer(from: metadata.components[0])
        var compP = DoViReshapeComponentBuffer(from: metadata.components[1])
        var compT = DoViReshapeComponentBuffer(from: metadata.components[2])
        
        // Tone mapping params
        let dynamicPeakPQ = metadata.sceneMaxPQ ?? metadata.sourceMaxPQ
        let dynamicPeakNits = ToneMapping.pqToNits(dynamicPeakPQ)
        
        var toneParams = ToneMappingParams(inputMin: 0.0, inputMax: dynamicPeakNits, outputMin: 0.0, outputMax: targetPeakNits)
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: [textures.y, textures.uv],
            configureEncoder: { encoder in
                encoder.setFragmentBytes(&doviParams, length: MemoryLayout<DoViParamsBuffer>.size, index: 0)
                encoder.setFragmentBytes(&compI, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 1)
                encoder.setFragmentBytes(&compP, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 2)
                encoder.setFragmentBytes(&compT, length: MemoryLayout<DoViReshapeComponentBuffer>.size, index: 3)
                encoder.setFragmentBytes(&toneParams, length: MemoryLayout<ToneMappingParams>.size, index: 4)
            }
        ) else { return false }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // Ensure completion for consistency
        
        return true
    }
    
    
    // MARK: - Tone Mapping (Pass 2)
    
    /// Renders an intermediate EDR texture (Linear P3) to SDR (BGRA8) using generic tone mapping
    private func renderToneMap(from sourceTexture: MTLTexture, to destinationTexture: MTLTexture) -> Bool {
        guard let pipelineState = toneMapPipelineState else { return false }
        
        var params = ToneMappingParams(
            inputMin: 0.0,
            inputMax: contentPeakNits,
            outputMin: 0.0,
            outputMax: ToneMapping.sdrPeakNits
        )
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: destinationTexture,
            viewportWidth: sourceTexture.width,
            viewportHeight: sourceTexture.height,
            textures: [sourceTexture],
            configureEncoder: { encoder in
                encoder.setFragmentBytes(&params, length: MemoryLayout<ToneMappingParams>.size, index: 0)
            }
        ) else { return false }
        
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
        
        currentRenderMode = "SDR NV12 (Float16)"

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createNV12Textures(from: pixelBuffer, bitDepth: 8) else { return false }
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: drawable.texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: [textures.y, textures.uv]
        ) else { return false }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    /// I420 rendering to rgba16Float target (for HDR-configured layers with SDR content)
    private func renderI420PixelBufferFloat16(
        _ pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable
    ) -> Bool {
        guard let pipelineState = i420Float16PipelineState else { return false }
        
        currentRenderMode = "SDR I420 (Float16)"

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0 && height > 0 else { return false }

        guard let textures = createI420Textures(from: pixelBuffer) else { return false }
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipelineState,
            targetTexture: drawable.texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: [textures.y, textures.u, textures.v]
        ) else { return false }

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

        // Output size
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

        // Offscreen target
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

        // DoVi pipeline
            // DoVi pipeline (2-pass)
        if let doviMetadata = frame.doviMetadata {
            // Create intermediate EDR texture
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: outputWidth, height: outputHeight, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let intermediateTexture = device.makeTexture(descriptor: desc) else { return nil }
            
            // Pass 1: DoVi -> EDR (Linear P3)
            // Use high peak nits to avoid tone mapping in the first pass
            if renderDoViToTexture(pixelBuffer, metadata: doviMetadata, to: intermediateTexture, targetPeakNits: 10000.0) {
                 // Pass 2: EDR -> SDR (Tone Mapped)
                 if renderToneMap(from: intermediateTexture, to: outputTexture) {
                     // Success
                 } else { return nil }
            } else { return nil }
        } else if frame.isHDR {
             // HDR pipeline (2-pass)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: outputWidth, height: outputHeight, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let intermediateTexture = device.makeTexture(descriptor: desc) else { return nil }
            
            if renderHDRToTexture(pixelBuffer, to: intermediateTexture, targetPeakNits: 10000.0) {
                if renderToneMap(from: intermediateTexture, to: outputTexture) {
                    // Success
                } else { return nil }
            } else { return nil }
        } else {
            // Render pixel buffer (SDR)
            if !renderPixelBufferToTexture(pixelBuffer, to: outputTexture) {
                return nil
            }
        }

        // Create CGImage
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
            pipelineState = nv12PipelineState  // Clamps HDR to SDR
            guard let t = createNV12Textures(from: pixelBuffer, bitDepth: 10) else { return false }
            textures = [t.y, t.uv]

        default:
            return renderPixelBufferToTextureWithCoreImage(pixelBuffer, to: texture)
        }

        guard let pipeline = pipelineState else { return false }
        
        guard let commandBuffer = performRenderPass(
            pipelineState: pipeline,
            targetTexture: texture,
            viewportWidth: width,
            viewportHeight: height,
            textures: textures
        ) else { return false }

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
        let bytesPerRow = width * 4  // 4 bpp

        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0
        )

        // Convert BGRA to RGBA
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
    
    /// Perform a generic render pass with the given configuration
    func performRenderPass(
        pipelineState: MTLRenderPipelineState,
        targetTexture: MTLTexture,
        viewportWidth: Int,
        viewportHeight: Int,
        textures: [MTLTexture],
        configureEncoder: ((MTLRenderCommandEncoder) -> Void)? = nil
    ) -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        
        let renderPassDescriptor = createBasicRenderPassDescriptor(for: targetTexture)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return nil }
        
        let viewport = Viewport(
            imageWidth: viewportWidth,
            imageHeight: viewportHeight,
            targetWidth: targetTexture.width,
            targetHeight: targetTexture.height
        )
        
        encoder.setRenderPipelineState(pipelineState)
        encoder.setViewport(viewport.mtlViewport)
        
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        
        configureEncoder?(encoder)
        
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        return commandBuffer
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
