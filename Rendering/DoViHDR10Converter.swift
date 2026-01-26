//
//  DoViHDR10Converter.swift
//  VidCore
//
//  Converts Dolby Vision Profile 5 frames to HDR10 (PQ BT.2020)
//  for System Renderer compatibility.
//

import Foundation
import CoreVideo
import Metal
import VideoToolbox

class DoViHDR10Converter {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var pixelBufferPool: CVPixelBufferPool?
    
    // Cache for buffer layout
    private var outputFormatDescription: CMFormatDescription?
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
        
        // Load library from the bundle containing this class
        let bundle = Bundle(for: DoViHDR10Converter.self)
        guard let library = try? device.makeDefaultLibrary(bundle: bundle) else {
            print("[DoViHDR10Converter] Failed to load Metal library")
            return nil
        }
        
        guard let function = library.makeFunction(name: "doviProfile5ToHDR10") else {
            print("[DoViHDR10Converter] Failed to find kernel 'doviProfile5ToHDR10'")
            return nil
        }
        
        do {
            self.computePipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("[DoViHDR10Converter] Failed to create pipeline state: \(error)")
            return nil
        }
        
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }
    
    func convert(frame: VideoFrame) -> VideoFrame? {
        guard let metadata = frame.doviMetadata,
              let textureCache = textureCache else {
            return nil // Not DoVi or not ready
        }
        
        let inputPixelBuffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(inputPixelBuffer)
        let height = CVPixelBufferGetHeight(inputPixelBuffer)
        
        // 1. Create Output Pool if needed
        if pixelBufferPool == nil {
            let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary
            let pixelBufferAttributes = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf, // RGBA16Float
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ] as CFDictionary
            
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes, pixelBufferAttributes, &pixelBufferPool)
        }
        
        guard let pool = pixelBufferPool else { return nil }
        
        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputPixelBuffer)
        
        guard let outputBuffer = outputPixelBuffer else { return nil }
        
        // 2. Create Textures
        // Input Y (Plane 0)
        var yTextureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, inputPixelBuffer, nil, .r16Unorm, width, height, 0, &yTextureRef)
        
        // Input UV (Plane 1)
        var uvTextureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, inputPixelBuffer, nil, .rg16Unorm, width / 2, height / 2, 1, &uvTextureRef)
        
        // Output RGBA
        var outTextureRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, outputBuffer, nil, .rgba16Float, width, height, 0, &outTextureRef)
        
        guard let yTex = CVMetalTextureGetTexture(yTextureRef!),
              let uvTex = CVMetalTextureGetTexture(uvTextureRef!),
              let outTex = CVMetalTextureGetTexture(outTextureRef!),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // 3. Prepare Uniforms
        var params = SysDoViParamsBuffer(from: metadata)
        var compI = SysDoViReshapeComponentBuffer(from: metadata.components[0])
        var compP = SysDoViReshapeComponentBuffer(from: metadata.components[1])
        var compT = SysDoViReshapeComponentBuffer(from: metadata.components[2])
        
        // 4. Encode
        encoder.setComputePipelineState(computePipelineState)
        encoder.setTexture(yTex, index: 0)
        encoder.setTexture(uvTex, index: 1)
        encoder.setTexture(outTex, index: 2)
        
        encoder.setBytes(&params, length: MemoryLayout<SysDoViParamsBuffer>.size, index: 0)
        encoder.setBytes(&compI, length: MemoryLayout<SysDoViReshapeComponentBuffer>.size, index: 1)
        encoder.setBytes(&compP, length: MemoryLayout<SysDoViReshapeComponentBuffer>.size, index: 2)
        encoder.setBytes(&compT, length: MemoryLayout<SysDoViReshapeComponentBuffer>.size, index: 3)
        
        let w = computePipelineState.threadExecutionWidth
        let h = computePipelineState.maxTotalThreadsPerThreadgroup / w
        let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
        let threadsPerGrid = MTLSizeMake(width, height, 1)
        
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted() // Blocking for simplicity in this system-render path
        
        // 5. Attach HDR Metadata to Output Buffer
        // It's now HDR10 (PQ / BT.2020)
        CVBufferSetAttachment(outputBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(outputBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(outputBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        
        // Pass L1 Scene Metadata (Dynamic HDR10 metadata handling)
        if let seiPayload = metadata.contentLightLevelData() {
            CVBufferSetAttachment(outputBuffer, kCVImageBufferContentLightLevelInfoKey, seiPayload as CFData, .shouldPropagate)
        }
        
        return VideoFrame(
            pixelBuffer: outputBuffer,
            presentationTime: frame.presentationTime,
            isHDR: true,
            doviMetadata: metadata, // Pass metadata through for L1 propagation in renderer
            colorTransfer: 16 // PQ
        )
    }
}
