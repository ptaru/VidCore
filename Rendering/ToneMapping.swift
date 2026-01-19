//
//  ToneMapping.swift
//  VidCore
//
//  Utility for HDR tone mapping and luminance conversion.
//

import AppKit

// MARK: - Tone Mapping Parameters

/// Configuration for HDR Tone Mapping (BT.2390).
/// Used to pass tone mapping parameters to Metal shaders.
public struct ToneMappingParams {
    public var inputMin: Float = 0.0
    public var inputMax: Float = 1000.0
    public var outputMin: Float = 0.0
    public var outputMax: Float = 1000.0

    public init(inputMin: Float = 0.0, inputMax: Float = 1000.0, outputMin: Float = 0.0, outputMax: Float = 1000.0) {
        self.inputMin = inputMin
        self.inputMax = inputMax
        self.outputMin = outputMin
        self.outputMax = outputMax
    }
}

// MARK: - Tone Mapping Utilities

/// Utility enum providing static helper functions for HDR tone mapping.
public enum ToneMapping {

    // MARK: - PQ Conversion

    /// Converts a PQ-encoded value (0.0-1.0) to absolute luminance in nits.
    /// - Parameter pq: The PQ value (0.0 - 1.0).
    /// - Returns: The luminance in nits (0.0 - 10000.0).
    public static func pqToNits(_ pq: Float) -> Float {
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

    // MARK: - Display Detection

    /// Detects the maximum potential brightness of the current screen in nits.
    /// - Returns: The peak brightness in nits. Returns 100.0 (SDR) if EDR is unavailable.
    public static func getCurrentScreenPeakNits() -> Float {
        guard let screen = NSScreen.main else { return 100.0 }

        // maximumExtendedDynamicRangeColorComponentValue:
        // 1.0 = SDR white (100 nits).
        // e.g. 16.0 = 1600 nits.
        let scalingFactor = Float(screen.maximumExtendedDynamicRangeColorComponentValue)

        // Clamp to reasonable limits
        return max(100.0, scalingFactor * 100.0)
    }

    // MARK: - Standard Parameters

    /// SDR output peak brightness in nits (100 nits).
    public static let sdrPeakNits: Float = 100.0

    /// Default HDR10 content peak brightness in nits (1000 nits).
    public static let hdr10DefaultPeakNits: Float = 1000.0
}
