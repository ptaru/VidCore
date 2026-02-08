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
/// rendering complexity and state management. It's designed to be a
/// near drop-in replacement for SwiftUI's `MediaPlayer` from AVKit.
///
/// ## Basic Usage
/// ```swift
/// @State private var player = MediaPlayer()
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

  private let player: MediaPlayer
  private let overlay: Overlay
  private let showsBuiltInControls: Bool
  private let allowsDebugMenu: Bool
  private let ownsPlayer: Bool
  private let url: URL?
  private let autoPlay: Bool

  @State private var internalPlayer: MediaPlayer?
  @State private var loadError: MediaPlayerError?
  @State private var showDebugInfo: Bool = false
  @Environment(\.displayScale) private var displayScale

  // MARK: - Initializers

  /// Creates a video player view with an existing player and optional overlay.
  ///
  /// Use this initializer when you need external control over the player,
  /// such as custom play/pause buttons or seeking.
  ///
  /// - Parameters:
  ///   - player: The `MediaPlayer` instance to display.
  ///   - showsBuiltInControls: Whether to show built-in loading, error, and finished states.
  ///     Defaults to `true`. Set to `false` when providing a complete custom UI.
  ///   - overlay: A view builder for content to display over the video.
  public init(
    player: MediaPlayer,
    showsBuiltInControls: Bool = true,
    allowsDebugMenu: Bool = false,
    @ViewBuilder overlay: () -> Overlay
  ) {
    self.player = player
    self.showsBuiltInControls = showsBuiltInControls
    self.allowsDebugMenu = allowsDebugMenu
    self.overlay = overlay()
    self.ownsPlayer = false
    self.url = nil
    self.autoPlay = false
  }

  // MARK: - Body

  public var body: some View {
    let activePlayer = internalPlayer ?? player

    ZStack {
      Color.black

      // Video rendering
      AVSystemVideoRenderer(player: activePlayer)

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
          debugStats: activePlayer.debugStats,
          selectedAudioTrackIndex: activePlayer.selectedAudioTrackIndex,
          onAudioTrackSelected: { index in
            Task {
              await activePlayer.selectAudioTrack(at: index)
            }
          },
          selectedSubtitleTrackIndex: activePlayer.selectedSubtitleTrackIndex,
          onSubtitleTrackSelected: { index in
            Task {
              await activePlayer.selectSubtitleTrack(at: index)
            }
          },
          playbackRate: activePlayer.playbackRate,
          onPlaybackRateChanged: { rate in
            activePlayer.playbackRate = rate
          },
          currentTime: activePlayer.currentTime
        )
      }

      // System Rendering Indicator

      // Subtitles
      if let videoInfo = activePlayer.videoInfo {
        GeometryReader { geo in
          SubtitleView(subtitle: activePlayer.currentSubtitle)
            .preference(key: SizePreferenceKey.self, value: geo.size)
            .onPreferenceChange(SizePreferenceKey.self) { size in
              Task {
                await MainActor.run {
                  activePlayer.viewSize = size
                  activePlayer.contentScale = displayScale
                }
              }
            }
        }
        .aspectRatio(CGSize(width: videoInfo.width, height: videoInfo.height), contentMode: .fit)
      } else {
        SubtitleView(subtitle: activePlayer.currentSubtitle)
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
    .onAppear {
      if ownsPlayer, internalPlayer == nil, let url = url {
        let p = player
        internalPlayer = p
        Task {
          do {
            try await p.load(url: url)
            if autoPlay {
              p.play()
            }
          } catch {
            // Error handled by player state mainly, but we can track load error
            // Player state sets .error()
          }
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
  ///   - player: The `MediaPlayer` instance to display.
  ///   - showsBuiltInControls: Whether to show built-in loading, error, and finished states.
  ///   - allowsDebugMenu: Whether to enable the debug info context menu. Defaults to `false`.
  public init(player: MediaPlayer, showsBuiltInControls: Bool = true, allowsDebugMenu: Bool = false)
  {
    self.init(
      player: player, showsBuiltInControls: showsBuiltInControls, allowsDebugMenu: allowsDebugMenu
    ) {
      EmptyView()
    }
  }

  /// Creates a self-contained video player that loads and plays a URL.
  ///
  /// This initializer creates an internal `MediaPlayer` and manages its
  /// entire lifecycle. The video loads automatically and plays when ready.
  /// Buffer sizes are automatically configured based on hardware acceleration detection.
  ///
  /// - Parameters:
  ///   - url: The URL of the video file to play.
  ///   - autoPlay: Whether to start playing automatically after loading. Defaults to `true`.
  ///   - allowsDebugMenu: Whether to enable the debug info context menu. Defaults to `false`.
  public init(url: URL, autoPlay: Bool = true, allowsDebugMenu: Bool = false) {
    // Create player with auto-detection for optimal buffer sizes
    self.player = MediaPlayer(url: url, buffers: .auto)
    self.showsBuiltInControls = true
    self.allowsDebugMenu = allowsDebugMenu
    self.overlay = EmptyView()
    self.ownsPlayer = true
    self.url = url
    self.autoPlay = autoPlay
    self._internalPlayer = State(initialValue: nil)
    self._loadError = State(initialValue: nil)
  }
}

// MARK: - Error View

/// Internal error display view
private struct VidPlayerErrorView: View {
  let error: MediaPlayerError

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

private struct SizePreferenceKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}
