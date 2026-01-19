//
//  VidPlayer.swift
//  VidCore
//
//  AVPlayer-like SwiftUI view for simplified video playback
//

import SwiftUI

/// A SwiftUI view that displays video content from a VidCore player.
///
/// `VidPlayer` provides an AVPlayer-like API for VidCore, encapsulating all
/// Metal rendering complexity and state management. It's designed to be a
/// near drop-in replacement for SwiftUI's `VideoPlayer` from AVKit.
///
/// ## Basic Usage
/// ```swift
/// @State private var player = VideoPlayer()
///
/// var body: some View {
///     VidPlayer(player: player)
///         .task {
///             try? await player.load(url: videoURL)
///             player.play()
///         }
/// }
/// ```
///
/// ## Self-Contained Playback
/// For the simplest use case, create a player that manages its own lifecycle:
/// ```swift
/// VidPlayer(url: videoURL)  // Loads and plays automatically
/// ```
///
/// ## Custom Overlay
/// Add custom controls or overlays on top of the video:
/// ```swift
/// VidPlayer(player: player) {
///     VStack {
///         Spacer()
///         CustomControlsView(player: player)
///     }
/// }
/// ```
///
/// ## Disabling Built-in Controls
/// When providing a full custom UI, disable built-in loading/error/finished states:
/// ```swift
/// VidPlayer(player: player, showsBuiltInControls: false) {
///     MyFullCustomUI(player: player)
/// }
/// ```
public struct VidPlayer<Overlay: View>: View {
    
    // MARK: - Properties
    
    private let player: VideoPlayer
    private let overlay: Overlay
    private let showsBuiltInControls: Bool
    private let allowsDebugMenu: Bool
    private let ownsPlayer: Bool
    
    @State private var internalPlayer: VideoPlayer?
    @State private var loadError: VideoPlayerError?
    @State private var showDebugInfo: Bool = false
    
    // MARK: - Initializers
    
    /// Creates a video player view with an existing player and optional overlay.
    ///
    /// Use this initializer when you need external control over the player,
    /// such as custom play/pause buttons or seeking.
    ///
    /// - Parameters:
    ///   - player: The `VideoPlayer` instance to display.
    ///   - showsBuiltInControls: Whether to show built-in loading, error, and finished states.
    ///     Defaults to `true`. Set to `false` when providing a complete custom UI.
    ///   - overlay: A view builder for content to display over the video.
    public init(
        player: VideoPlayer,
        showsBuiltInControls: Bool = true,
        allowsDebugMenu: Bool = false,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.player = player
        self.showsBuiltInControls = showsBuiltInControls
        self.allowsDebugMenu = allowsDebugMenu
        self.overlay = overlay()
        self.ownsPlayer = false
    }
    
    // MARK: - Body
    
    public var body: some View {
        let activePlayer = internalPlayer ?? player
        
        ZStack {
            Color.black
            
            // Video rendering
            if let renderingEngine = activePlayer.renderingEngine {
                MetalVideoRenderer(
                    renderingEngine: renderingEngine,
                    currentFrame: Binding(
                        get: { activePlayer.currentFrame },
                        set: { _ in }
                    )
                )
            }
            
            // Built-in controls (can be disabled)
            if showsBuiltInControls {
                // Loading state
                if activePlayer.state == .loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(1.5)
                        .tint(.white)
                }
                
                // Error state
                if case .error(let error) = activePlayer.state {
                    VidPlayerErrorView(error: error)
                }
                
                // Custom error from URL loading
                if let error = loadError {
                    VidPlayerErrorView(error: error)
                }
                
                // Finished state - replay button
                if activePlayer.state == .finished {
                    Button(action: { activePlayer.play() }) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(radius: 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Debug info overlay (top-left corner)
            if showDebugInfo, let frame = activePlayer.currentFrame {
                VidPlayerDebugOverlay(
                    frame: frame,
                    videoInfo: activePlayer.videoInfo,
                    renderingEngine: activePlayer.renderingEngine
                )
            }
            
            // User overlay
            overlay
        }
        .contextMenu {
            if allowsDebugMenu {
                Button(action: { showDebugInfo.toggle() }) {
                    Label(
                        showDebugInfo ? "Hide Debug Info" : "Show Debug Info",
                        systemImage: showDebugInfo ? "info.circle.fill" : "info.circle"
                    )
                }
            }
        }
        .onDisappear {
            // Clean up owned player
            if ownsPlayer, let player = internalPlayer {
                Task {
                    await player.close()
                }
            }
        }
    }
}

// MARK: - Convenience Initializers

extension VidPlayer where Overlay == EmptyView {
    
    /// Creates a video player view with an existing player.
    ///
    /// - Parameters:
    ///   - player: The `VideoPlayer` instance to display.
    ///   - showsBuiltInControls: Whether to show built-in loading, error, and finished states.
    ///   - allowsDebugMenu: Whether to enable the debug info context menu. Defaults to `false`.
    public init(player: VideoPlayer, showsBuiltInControls: Bool = true, allowsDebugMenu: Bool = false) {
        self.init(player: player, showsBuiltInControls: showsBuiltInControls, allowsDebugMenu: allowsDebugMenu) {
            EmptyView()
        }
    }
    
    /// Creates a self-contained video player that loads and plays a URL.
    ///
    /// This initializer creates an internal `VideoPlayer` and manages its
    /// entire lifecycle. The video loads automatically and plays when ready.
    ///
    /// - Parameters:
    ///   - url: The URL of the video file to play.
    ///   - autoPlay: Whether to start playing automatically after loading. Defaults to `true`.
    ///   - allowsDebugMenu: Whether to enable the debug info context menu. Defaults to `false`.
    public init(url: URL, autoPlay: Bool = true, allowsDebugMenu: Bool = false) {
        // Create a placeholder player - the real one is created in onAppear
        self.player = VideoPlayer()
        self.showsBuiltInControls = true
        self.allowsDebugMenu = allowsDebugMenu
        self.overlay = EmptyView()
        self.ownsPlayer = true
        self._internalPlayer = State(initialValue: nil)
        self._loadError = State(initialValue: nil)
    }
}

// MARK: - URL-Based VidPlayer

/// Self-contained SwiftUI view that loads and plays a video URL automatically.
///
/// Use this for the simplest playback scenario where you don't need external control.
/// ```swift
/// VidPlayerURL(url: videoURL)
/// ```
public struct VidPlayerURL: View {
    private let url: URL
    private let autoPlay: Bool
    
    @State private var player = VideoPlayer()
    @State private var loadError: VideoPlayerError?
    
    /// Creates a self-contained video player that loads and plays a URL.
    ///
    /// - Parameters:
    ///   - url: The URL of the video file to play.
    ///   - autoPlay: Whether to start playing automatically after loading. Defaults to `true`.
    public init(url: URL, autoPlay: Bool = true) {
        self.url = url
        self.autoPlay = autoPlay
    }
    
    public var body: some View {
        ZStack {
            Color.black
            
            if let renderingEngine = player.renderingEngine {
                MetalVideoRenderer(
                    renderingEngine: renderingEngine,
                    currentFrame: Binding(
                        get: { player.currentFrame },
                        set: { _ in }
                    )
                )
            }
            
            // Loading state
            if player.state == .loading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)
                    .tint(.white)
            }
            
            // Error state
            if case .error(let error) = player.state {
                VidPlayerErrorView(error: error)
            }
            
            if let error = loadError {
                VidPlayerErrorView(error: error)
            }
            
            // Finished state
            if player.state == .finished {
                Button(action: { player.play() }) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(radius: 8)
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            do {
                try await player.load(url: url)
                if autoPlay {
                    player.play()
                }
            } catch let error as VideoPlayerError {
                loadError = error
            } catch {
                loadError = .decoderInitFailed(error.localizedDescription)
            }
        }
        .onDisappear {
            Task {
                await player.close()
            }
        }
    }
    
    /// Access to the underlying player for external control.
    public var videoPlayer: VideoPlayer {
        player
    }
}

// MARK: - Error View

/// Internal error display view
private struct VidPlayerErrorView: View {
    let error: VideoPlayerError
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.yellow)
            Text(error.errorDescription ?? "An error occurred")
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .font(.callout)
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
    }
}

// MARK: - Debug Overlay

/// Debug overlay showing comprehensive video info (right-click to toggle)
private struct VidPlayerDebugOverlay: View {
    let frame: VideoFrame
    let videoInfo: VideoInfo?
    let renderingEngine: RenderingEngine?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack {
                Image(systemName: "info.circle.fill")
                Text("Debug Info")
                    .fontWeight(.semibold)
            }
            .font(.caption)
            
            Divider()
                .background(Color.white.opacity(0.5))
            
            // MARK: Video Info Section
            if let info = videoInfo {
                debugRow("Resolution", "\(info.width)×\(info.height)")
                debugRow("Frame Rate", String(format: "%.2f fps", info.frameRate))
                debugRow("Codec", info.codecName.uppercased())
                
                // Detailed decoder info
                if let decoderName = info.decoderName {
                    debugRow("Decoder", decoderName)
                }
                debugRow("HW Accel", info.isHardwareAccelerated ? "Yes (VideoToolbox)" : "No (Software)")
            }
            
            // Rendering Info
            if let engine = renderingEngine {
                Divider().background(Color.white.opacity(0.3))
                
                debugRow("Pipeline", engine.currentRenderMode)
                debugRow("Display Peak", String(format: "%.0f nits", engine.currentDisplayPeakNits))
            }
            
            // Pixel Format & Bit Depth
            let pixelInfo = pixelFormatInfo(from: frame.pixelBuffer)
            debugRow("Pixel Format", pixelInfo.format)
            debugRow("Bit Depth", pixelInfo.bitDepth)
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // MARK: HDR/Color Section
            if let info = videoInfo {
                debugRow("Transfer", info.transferFunctionName)
                debugRow("Primaries", info.colorPrimariesName)
                debugRow("Color Space", info.colorSpaceName)
                debugRow("Range", info.colorRange == 2 ? "Full" : "Limited")
            }
            
            // HDR status - DoVi is always HDR
            let isHDRContent = frame.isHDR || (videoInfo?.isDolbyVision ?? false) || frame.doviMetadata != nil
            if isHDRContent {
                debugRow("HDR", "Yes")
            } else {
                debugRow("HDR", "No (SDR)")
            }
            
            // DoVi Status
            if let dovi = frame.doviMetadata {
                debugRow("Dolby Vision", "Profile 5")
                debugRow("Source Range", String(format: "%.3f - %.3f PQ", dovi.sourceMinPQ, dovi.sourceMaxPQ))
                
                // L1 Scene Brightness
                if let l1Max = renderingEngine?.lastL1SceneMaxNits {
                    debugRow("L1 Scene Max", String(format: "%.0f nits", l1Max))
                } else if let sceneMax = dovi.sceneMaxPQ {
                     debugRow("L1 Scene Max", String(format: "%.3f PQ (%.0f nits)", sceneMax, pqToNits(sceneMax)))
                }
                if let sceneAvg = dovi.sceneAvgPQ {
                    debugRow("L1 Scene Avg", String(format: "%.3f PQ (%.0f nits)", sceneAvg, pqToNits(sceneAvg)))
                }
                if dovi.sceneMaxPQ == nil {
                    debugRow("L1 Data", "Not present")
                }
            } else if let info = videoInfo, info.isDolbyVision {
                debugRow("Dolby Vision", "Profile 8 (EDR)")
            } else {
                debugRow("Dolby Vision", "No")
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // MARK: Audio Section
            if let info = videoInfo, let audioCodec = info.audioCodecName {
                let sampleRate = info.audioSampleRate ?? 0
                let channels = info.audioChannels ?? 0
                let channelStr = channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels)ch"
                debugRow("Audio", "\(audioCodec.uppercased()) \(sampleRate/1000)kHz \(channelStr)")
            } else {
                debugRow("Audio", "None")
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            // MARK: Timing Section
            debugRow("PTS", String(format: "%.3fs", frame.presentationTime))
            if let info = videoInfo {
                let frameNumber = Int(frame.presentationTime * info.frameRate)
                debugRow("Frame #", "\(frameNumber)")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(8)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
    
    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.gray)
            Text(value)
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
