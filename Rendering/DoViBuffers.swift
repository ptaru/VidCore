//
//  DoViBuffers.swift
//  VidCore
//
//  Internal Metal buffer structures for Dolby Vision processing
//

import Foundation
import simd

/// Metal buffer struct matching DoViReshapeComponent in VideoShaders.metal
/// Total size: 36 + 128 + 768 + 4 + 12 = 948 bytes (aligned to 960)
internal struct DoViReshapeComponentBuffer {
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
internal struct DoViParamsBuffer {
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
        // lms2rgb = hpeLms2Rgb * metadata.linearMatrix
        lms2rgbMatrix = hpeLms2Rgb * metadata.linearMatrix
        
        sourceMinPQ = metadata.sourceMinPQ
        sourceMaxPQ = metadata.sourceMaxPQ
    }
}
