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
    private let ownsPlayer: Bool
    
    @State private var internalPlayer: VideoPlayer?
    @State private var loadError: VideoPlayerError?
    
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
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.player = player
        self.showsBuiltInControls = showsBuiltInControls
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
            
            // User overlay
            overlay
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
    public init(player: VideoPlayer, showsBuiltInControls: Bool = true) {
        self.init(player: player, showsBuiltInControls: showsBuiltInControls) {
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
    public init(url: URL, autoPlay: Bool = true) {
        // Create a placeholder player - the real one is created in onAppear
        self.player = VideoPlayer()
        self.showsBuiltInControls = true
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
