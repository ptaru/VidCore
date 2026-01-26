//
//  VidPlayerDebugOverlay.swift
//  VidCore
//
//  Debug overlay for VidPlayer
//

import SwiftUI
import CoreVideo

/// Debug overlay showing comprehensive video info (right-click to toggle)
struct VidPlayerDebugOverlay: View {
    let frame: VideoFrame
    let videoInfo: VideoInfo?
    let debugStats: PlayerDebugStats?
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left Column: Pipeline & Timing
            VStack(alignment: .leading, spacing: 4) {
                header("Pipeline & Timing")
                
                // Pipeline Stats
                if let stats = debugStats {
                    Group {
                        debugRow("State", "Playing") // Dynamic in future
                        debugRow("Decoder", stats.isHardwareDecoded ? "Hardware (VT)" : "Software (FFmpeg)")
                        
                        // Buffer Health
                        let pqPct = Double(stats.packetQueueCount) / Double(max(1, stats.packetQueueMax)) * 100
                        let fbPct = Double(stats.frameBufferCount) / Double(max(1, stats.frameBufferMax)) * 100
                        debugBar("Packet Queue", percent: pqPct, label: "\(stats.packetQueueCount)/\(stats.packetQueueMax)")
                        debugBar("Frame Buffer", percent: fbPct, label: "\(stats.frameBufferCount)/\(stats.frameBufferMax)")
                        
                        if stats.droppedFrameCount > 0 {
                            debugRow("Dropped Frames", "\(stats.droppedFrameCount)", color: .orange)
                        }
                    }
                }
                
                Divider().background(Color.white.opacity(0.3))
                
                // Timing
                Group {
                    debugRow("PTS", String(format: "%.3fs", frame.presentationTime))
                    if let info = videoInfo {
                        let frameNumber = Int(frame.presentationTime * info.frameRate)
                        debugRow("Frame #", "\(frameNumber)")
                    }
                    if let stats = debugStats {
                        let driftMs = stats.avDrift * 1000
                        let color: Color = abs(driftMs) > 100 ? .red : abs(driftMs) > 50 ? .orange : .white
                        debugRow("A/V Drift", String(format: "%+.1f ms", driftMs), color: color)
                    }
                }
            }
            
            Divider().background(Color.white.opacity(0.3))
            
            // Middle Column: Video Format & Color
            VStack(alignment: .leading, spacing: 4) {
                header("Video & Color")
                
                if let info = videoInfo {
                    debugRow("Resolution", "\(info.width)×\(info.height)")
                    debugRow("Frame Rate", String(format: "%.2f fps", info.frameRate))
                    debugRow("Codec", info.codecName.uppercased())
                }
                
                let pixelInfo = pixelFormatInfo(from: frame.pixelBuffer)
                debugRow("Pixel Format", pixelInfo.format)
                debugRow("Bit Depth", pixelInfo.bitDepth)
                
                Divider().background(Color.white.opacity(0.3))
                
                // Color Info
                if let info = videoInfo {
                    debugRow("Transfer", info.transferFunctionName)
                    debugRow("Primaries", info.colorPrimariesName)
                    debugRow("Range", info.colorRange == 2 ? "Full" : "Limited")
                    
                    // HDR/DoVi
                    if frame.doviProfile > 0 {
                        debugRow("Dolby Vision", "Profile \(frame.doviProfile)")
                    }
                    
                    if info.isHDR || info.isDolbyVision {
                        debugRow("HDR Mode", "Active", color: .green)
                        if let maxCLL = info.maxContentLightLevel {
                            debugRow("MaxCLL", "\(maxCLL) nits")
                        }
                        if let maxFALL = info.maxFrameAverageLightLevel {
                            debugRow("MaxFALL", "\(maxFALL) nits")
                        }
                        debugRow("Content Peak", String(format: "%.0f nits", info.contentPeakNits))
                    } else {
                        debugRow("SDR", "Active")
                    }
                }
            }
            
            Divider().background(Color.white.opacity(0.3))
            
            // Right Column: Audio & Metadata
            VStack(alignment: .leading, spacing: 4) {
                header("Audio & Metadata")
                
                if let info = videoInfo, let audioCodec = info.audioCodecName {
                    debugRow("Codec", audioCodec.uppercased())
                    if let rate = info.audioSampleRate {
                        debugRow("Rate", String(format: "%.1f kHz", Double(rate)/1000.0))
                    }
                    if let channels = info.audioChannels {
                        debugRow("Channels", channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels)ch")
                    }
                } else {
                    debugRow("Audio", "None", color: .gray)
                }
                
                if let dovi = frame.doviMetadata {
                    Divider().background(Color.white.opacity(0.3))
                    header("DoVi Dynamic Data")
                    if let sceneMax = dovi.sceneMaxPQ {
                        debugRow("L1 Scene Max", String(format: "%.0f nits", pqToNits(sceneMax)))
                    }
                    if let sceneAvg = dovi.sceneAvgPQ {
                        debugRow("L1 Scene Avg", String(format: "%.0f nits", pqToNits(sceneAvg)))
                    }
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(12)
        .background(Color.black.opacity(0.85))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .fixedSize()
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private func header(_ text: String) -> some View {
        Text(text)
            .fontWeight(.bold)
            .padding(.bottom, 2)
            .foregroundColor(.white.opacity(0.9))
    }
    
    private func debugRow(_ label: String, _ value: String, color: Color = .white) -> some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.gray)
            Text(value)
                .foregroundColor(color)
        }
    }
    
    private func debugBar(_ label: String, percent: Double, label valueLabel: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.gray)
            
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                    Rectangle()
                        .fill(percent > 80 ? Color.green : percent > 40 ? Color.yellow : Color.red)
                        .frame(width: g.size.width * CGFloat(percent / 100.0))
                }
            }
            .frame(width: 50, height: 6)
            
            Text(valueLabel)
        }
    }
    
    /// Returns pixel format name and bit depth from CVPixelBuffer
    private func pixelFormatInfo(from pixelBuffer: CVPixelBuffer) -> (format: String, bitDepth: String) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return ("NV12", "8-bit")
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return ("NV12 Full", "8-bit")
        case kCVPixelFormatType_420YpCbCr8Planar:
            return ("I420", "8-bit")
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return ("P010", "10-bit")
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return ("P010 Full", "10-bit")
        case kCVPixelFormatType_32BGRA:
            return ("BGRA", "8-bit")
        case kCVPixelFormatType_64RGBALE:
            return ("RGBA16", "16-bit")
        case kCVPixelFormatType_4444AYpCbCr16:
            return ("YUV444-16", "16-bit")
        default:
            let chars = [
                Character(UnicodeScalar((format >> 24) & 0xFF)!),
                Character(UnicodeScalar((format >> 16) & 0xFF)!),
                Character(UnicodeScalar((format >> 8) & 0xFF)!),
                Character(UnicodeScalar(format & 0xFF)!)
            ]
            return (String(chars), "Unknown")
        }
    }
    
    /// Converts PQ value (0.0-1.0) to nits for display
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
}
