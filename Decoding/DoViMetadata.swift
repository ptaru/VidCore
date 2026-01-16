//
//  DoViMetadata.swift
//  VidCore
//
//  Dolby Vision Profile 5 metadata structures for IPTPQc2 decoding
//

import Foundation
import simd

/// Dolby Vision reshape method for each pivot interval
public enum DoViReshapeMethod: UInt8 {
    case polynomial = 0  // s = c2*s² + c1*s + c0
    case mmr = 1         // Multivariate Multiple Regression
}

/// Per-component reshape data (I, P, or T channel)
/// Matches standard reshape data structure
public struct DoViReshapeData {
    /// Number of pivot points (2-9)
    public var numPivots: UInt8 = 0
    
    /// Pivot values, normalized to [0.0, 1.0] based on base layer bit depth
    public var pivots: [Float] = Array(repeating: 0, count: 9)
    
    /// Reshape method for each interval (numPivots - 1 intervals)
    public var method: [DoViReshapeMethod] = Array(repeating: .polynomial, count: 8)
    
    /// Polynomial coefficients [interval][c0, c1, c2]
    /// s_out = c2*s² + c1*s + c0
    public var polyCoeffs: [[Float]] = Array(repeating: [0, 0, 0], count: 8)
    
    /// MMR order (1, 2, or 3) for each interval
    public var mmrOrder: [UInt8] = Array(repeating: 0, count: 8)
    
    /// MMR constant term for each interval
    public var mmrConstant: [Float] = Array(repeating: 0, count: 8)
    
    /// MMR coefficients [interval][order][7 coefficients]
    /// Order 1: 7 coeffs (3 for sig + 4 for sigX)
    /// Order 2: +7 more (3 for sig² + 4 for sigX²)
    /// Order 3: +7 more (3 for sig³ + 4 for sigX³)
    public var mmrCoeffs: [[[Float]]] = Array(repeating: Array(repeating: Array(repeating: 0, count: 7), count: 3), count: 8)
    
    public init() {}
}

/// Complete Dolby Vision metadata for one frame
/// Contains color matrices and reshape curves for Profile 5 IPTPQc2 decoding
public struct DoViMetadata {
    // MARK: - Color Matrices
    
    /// Offset applied before nonlinear matrix ("ycc_to_rgb_offset")
    public var nonlinearOffset: SIMD3<Float> = .zero
    
    /// Nonlinear transformation matrix ("ycc_to_rgb", applied in PQ domain)
    /// Transforms reshaped IPT → LMS (still PQ-encoded)
    public var nonlinearMatrix: matrix_float3x3 = matrix_identity_float3x3
    
    /// Linear transformation matrix ("rgb_to_lms")
    /// Combined with HPE inverse to form LMS → RGB
    public var linearMatrix: matrix_float3x3 = matrix_identity_float3x3
    
    // MARK: - Reshape Data
    
    /// Reshape data for I, P, T components
    public var components: [DoViReshapeData] = [DoViReshapeData(), DoViReshapeData(), DoViReshapeData()]
    
    // MARK: - Luminance Metadata
    
    /// Source minimum luminance in PQ [0-1]
    public var sourceMinPQ: Float = 0
    
    /// Source maximum luminance in PQ [0-1]
    public var sourceMaxPQ: Float = 1
    
    public init() {}
    
    /// Initialize from ObjC dictionary (bridged from FFmpegDecoder)
    public init?(fromDictionary dict: [String: Any]) {
        guard let nonlinearMatrixArray = dict["nonlinearMatrix"] as? [NSNumber],
              let linearMatrixArray = dict["linearMatrix"] as? [NSNumber],
              let nonlinearOffsetArray = dict["nonlinearOffset"] as? [NSNumber],
              let componentsArray = dict["components"] as? [[String: Any]],
              nonlinearMatrixArray.count == 9,
              linearMatrixArray.count == 9,
              nonlinearOffsetArray.count == 3,
              componentsArray.count == 3
        else {
            return nil
        }
        
        // Parse matrices (row-major to column-major for simd)
        self.nonlinearMatrix = matrix_float3x3(columns: (
            SIMD3<Float>(nonlinearMatrixArray[0].floatValue, nonlinearMatrixArray[3].floatValue, nonlinearMatrixArray[6].floatValue),
            SIMD3<Float>(nonlinearMatrixArray[1].floatValue, nonlinearMatrixArray[4].floatValue, nonlinearMatrixArray[7].floatValue),
            SIMD3<Float>(nonlinearMatrixArray[2].floatValue, nonlinearMatrixArray[5].floatValue, nonlinearMatrixArray[8].floatValue)
        ))
        
        self.linearMatrix = matrix_float3x3(columns: (
            SIMD3<Float>(linearMatrixArray[0].floatValue, linearMatrixArray[3].floatValue, linearMatrixArray[6].floatValue),
            SIMD3<Float>(linearMatrixArray[1].floatValue, linearMatrixArray[4].floatValue, linearMatrixArray[7].floatValue),
            SIMD3<Float>(linearMatrixArray[2].floatValue, linearMatrixArray[5].floatValue, linearMatrixArray[8].floatValue)
        ))
        
        self.nonlinearOffset = SIMD3<Float>(
            nonlinearOffsetArray[0].floatValue,
            nonlinearOffsetArray[1].floatValue,
            nonlinearOffsetArray[2].floatValue
        )
        
        self.sourceMinPQ = (dict["sourceMinPQ"] as? NSNumber)?.floatValue ?? 0
        self.sourceMaxPQ = (dict["sourceMaxPQ"] as? NSNumber)?.floatValue ?? 1
        
        for (i, compDict) in componentsArray.enumerated() {
            var comp = DoViReshapeData()
            
            comp.numPivots = (compDict["numPivots"] as? NSNumber)?.uint8Value ?? 0
            
            if let pivots = compDict["pivots"] as? [NSNumber] {
                for (j, p) in pivots.prefix(9).enumerated() {
                    comp.pivots[j] = p.floatValue
                }
            }
            
            if let methods = compDict["methods"] as? [NSNumber] {
                for (j, m) in methods.prefix(8).enumerated() {
                    comp.method[j] = m.uint8Value == 1 ? .mmr : .polynomial
                }
            }
            
            if let polyCoeffs = compDict["polyCoeffs"] as? [[NSNumber]] {
                for (j, coeffs) in polyCoeffs.prefix(8).enumerated() {
                    comp.polyCoeffs[j] = coeffs.prefix(3).map { $0.floatValue }
                    while comp.polyCoeffs[j].count < 3 {
                        comp.polyCoeffs[j].append(0)
                    }
                }
            }
            
            if let mmrOrders = compDict["mmrOrders"] as? [NSNumber] {
                for (j, order) in mmrOrders.prefix(8).enumerated() {
                    comp.mmrOrder[j] = order.uint8Value
                }
            }
            
            if let mmrConstants = compDict["mmrConstants"] as? [NSNumber] {
                for (j, constant) in mmrConstants.prefix(8).enumerated() {
                    comp.mmrConstant[j] = constant.floatValue
                }
            }
            
            if let mmrCoeffsArray = compDict["mmrCoeffs"] as? [[[NSNumber]]] {
                for (j, orderCoeffs) in mmrCoeffsArray.prefix(8).enumerated() {
                    for (k, coeffs) in orderCoeffs.prefix(3).enumerated() {
                        comp.mmrCoeffs[j][k] = coeffs.prefix(7).map { $0.floatValue }
                        while comp.mmrCoeffs[j][k].count < 7 {
                            comp.mmrCoeffs[j][k].append(0)
                        }
                    }
                }
            }
            
            self.components[i] = comp
        }
    }
}
