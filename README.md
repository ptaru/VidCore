# VidCore

A video decoding and rendering framework for macOS built on FFmpeg.

## Overview

VidCore provides high-performance video playback capabilities for macOS applications. It handles container formats (MKV, WebM, AVI, MP4), hardware-accelerated passthrough via sample buffers, and system-integrated rendering via `AVSampleBufferDisplayLayer`.

## Features

- **FFmpeg Decoding**: Support for diverse codecs (H.264, H.265/HEVC, VP8, VP9, AV1 via dav1d, etc.)
- **Hardware Acceleration**: Automatic passthrough sample buffers when available
- **System-Integrated Rendering**: Uses `AVSampleBufferDisplayLayer` for power-efficient, color-perfect rendering of SDR, and HDR content
- **HDR Support**: DoVi, HDR10, and HLG support with BT.2020 color primaries and proper EDR signaling
- **Tone Mapping**: Automatic system-level tone mapping using dynamic metadata where available
- **Audio Playback**: System-scheduled audio via AVSampleBufferAudioRenderer (with AVAudioEngine fallback for app extensions; best-effort sync)
  - Quick Look runs in an app extension, so VidCore automatically switches to AVAudioEngine there.
  - For testing the fallback in a normal app, set `VIDCORE_FORCE_AUDIO_ENGINE=1` in the environment.
- **SwiftUI Integration**: Drop-in `VidPlayer` view with optional debug overlay, similar to AVKit's `VideoPlayer`
- **Async/Await API**: Modern Swift concurrency with parallel demux/decode pipelines
- **Optimized Buffering**: Intelligent buffer management with CVPixelBufferPool and frame reordering for multi-threaded decoders
- **Optimized Seeking**: Zero-latency scrub interaction with two-phase seek (instant jump + precise refinement)

## Requirements

- macOS 15.0+
- Xcode 15.0+

## Building

### 1. Build FFmpeg

If the bundled libraries are missing, build them:

```bash
# Install build tools (one-time)
brew install nasm meson ninja pkg-config

# Build FFmpeg + dav1d (~5-10 min)
cd Scripts
chmod +x build-ffmpeg.sh
./build-ffmpeg.sh
```

This creates universal static libraries (arm64 + x86_64) in `Frameworks/FFmpeg/`.

### 2. Xcode Project Configuration

To build `VidCore.framework`, the project is configured with:

- **System Headers**: FFmpeg headers are included via `-isystem` in **Other C Flags** and **Other C++ Flags** to suppress warnings within external code.
- **Static Linking**: The target links against the `.a` files in `Frameworks/FFmpeg/lib`.

### 3. Using VidCore in Another Project

To add `VidCore` to your own macOS application:

1.  **Embed the Framework**:
    - Drag `VidCore.xcodeproj` into your project.
    - In your app target's **General** tab, add `VidCore.framework` to **Frameworks, Libraries, and Embedded Content**.
    - Set it to **Embed & Sign**.
2.  **Configure Transitive Dependencies**:
    Since `VidCore` links statically to FFmpeg, your app needs to know where those libraries are for the final link stage. In your app's **Build Settings**:
    - Add the path to `VidCore/Frameworks/FFmpeg/lib` to **Library Search Paths**.
3.  **Import**:
    ```swift
    import VidCore
    ```

---

The following documentation may be out of date and not fully reflect the latest features of VidCore, please rely on the DocC documentation where possible. 

## Quick Start

### Basic Playback
The simplest way to play a video is using the `VidPlayer` view with a URL. This handles loading, playback, and error states automatically.

```swift
import SwiftUI
import VidCore

struct ContentView: View {
    let videoURL: URL
    
    var body: some View {
        // Auto-play with debug overlay enabled
        VidPlayer(url: videoURL, autoPlay: true, allowsDebugMenu: true)
            .edgesIgnoringSafeArea(.all)
    }
}
```

### Advanced Control
For fine-grained control (play/pause, seek, metadata), create a `VideoPlayer` instance.

```swift
import SwiftUI
import VidCore

struct PlayerView: View {
    let videoURL: URL
    @State private var player = VideoPlayer()
    
    var body: some View {
        VStack {
            VidPlayer(player: player)
                .task {
                    // Load and play
                    try? await player.load(url: videoURL)
                    player.play()
                }
            
            // Custom controls
            HStack {
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                
                if let info = player.videoInfo, info.isHDR {
                    Text("HDR: \(info.transferFunctionName)")
                        .foregroundStyle(.green)
                }
            }
            .padding()
        }
    }
}
```

---

## Usage Guide

### SwiftUI Integration

VidCore provides `VidPlayer` for SwiftUI integration with multiple initialization options:

#### VidPlayer with URL (Self-Contained)

For simple playback where the player manages its own lifecycle:

```swift
VidPlayer(url: videoURL)                                     // Auto-plays
VidPlayer(url: videoURL, autoPlay: false)                    // Load only, manual play
VidPlayer(url: videoURL, autoPlay: true, allowsDebugMenu: true)  // With debug overlay
```

#### VidPlayer (Controlled)

For full control over playback:

```swift
@State private var player = VideoPlayer()

VidPlayer(player: player)
    .task {
        try? await player.load(url: videoURL)
        player.play()
    }
```

#### Custom Overlays

Add custom controls on top of the video (like AVKit's `VideoPlayer`):

```swift
VidPlayer(player: player) {
    VStack {
        Spacer()
        CustomControlsBar(player: player)
    }
}
```

#### Disabling Built-in UI

When providing a complete custom UI, disable the built-in loading/error/finished states:

```swift
VidPlayer(player: player, showsBuiltInControls: false) {
    MyFullCustomUI(player: player)
}
```

---

### VideoPlayer API

The `VideoPlayer` class is the core playback controller:

```swift
let player = VideoPlayer()

// Load
try await player.load(url: videoURL)

// Playback control
player.play()
player.pause()
player.togglePlayPause()

// Seeking
await player.seek(to: 30.0, accurate: true)   // Seek to 30s, frame-accurate
await player.seek(to: 30.0, accurate: false)  // Seek to nearest keyframe (faster)

// Volume
player.volume = 0.5        // 0.0 to 1.0
player.isMuted = true
player.toggleMute()

// State observation (works with SwiftUI @Observable)
player.state              // .idle, .loading, .ready, .playing, .paused, .seeking, .finished, .error
player.currentTime        // Current playback position in seconds
player.duration           // Total duration in seconds
player.isPlaying          // Convenience for state == .playing

// Metadata
if let info = player.videoInfo {
    // Basic
    print("\(info.width)x\(info.height) @ \(info.frameRate)fps")
    print("Duration: \(info.duration)s")
    print("Codec: \(info.codecName) (HW accel: \(info.isHardwareAccelerated))")
    
    // HDR & Color
    if info.isHDR {
        print("HDR Type: \(info.transferFunctionName)") // PQ or HLG
        print("Bit Depth: \(info.bitsPerComponent)-bit")
        print("Color: \(info.colorPrimariesName) / \(info.colorSpaceName)")
        
        if info.isDolbyVision {
             print("Dolby Vision Profile: \(info.doviProfile ?? 0)")
        }
        
        // Tone Mapping helper
        print("Content Peak: \(info.contentPeakNits) nits")
    }
    
    // Audio
    if let audioCodec = info.audioCodecName {
        print("Audio: \(audioCodec) \(info.audioChannels ?? 0)ch @ \(info.audioSampleRate ?? 0)Hz")
    }
    
    // Audio Tracks
    for track in info.audioTracks {
        let selected = track.streamIndex == player.selectedAudioTrackIndex ? "✓" : " "
        print("\(selected) \(track.displayName)")
    }
}

// Cleanup
await player.close()
```

#### Audio Track Selection

Select from multiple audio tracks (common in MKV/MP4 with multiple languages):

```swift
// List available tracks
for (index, track) in player.audioTracks.enumerated() {
    let marker = index == player.selectedAudioTrackIndex ? "→" : "  "
    print("\(marker) \(track.displayName)")
}

// Switch to a different track (e.g., Japanese audio)
if let japaneseIndex = player.audioTracks.firstIndex(where: { $0.language == "jpn" }) {
    await player.selectAudioTrack(at: japaneseIndex)
}
```

---

### Low-Level API (Advanced)

#### VideoDecoder

For building custom decode pipelines with parallel demux/decode:

```swift
let decoder = try VideoDecoder(url: videoURL)

// Access metadata
print("Resolution: \(decoder.videoInfo.width)x\(decoder.videoInfo.height)")
print("Duration: \(decoder.videoInfo.duration)s")
print("Hardware accelerated: \(decoder.videoInfo.isHardwareAccelerated)")

// Demux and decode loop
while let packet = await decoder.demuxNextPacket() {
    let frames = await decoder.decodePacket(packet)
    
    for frame in frames {
        switch frame {
        case .video(let videoFrame):
            // videoFrame.pixelBuffer contains the CVPixelBuffer
            // videoFrame.presentationTime is the PTS in seconds
        case .audio(let pcmBuffer, let pts):
            // pcmBuffer is an AVAudioPCMBuffer
        }
    }
}

// End of stream - flush decoder for remaining frames
await decoder.flushVideoDecoder()
while let frame = await decoder.drainVideoFrame() {
    // Process remaining buffered frames
}

decoder.close()
```

#### Audio Track Management (Low-Level)

The VideoDecoder also provides low-level access to audio tracks:

```swift
let decoder = try VideoDecoder(url: videoURL)

// Get available tracks
let tracks = decoder.getAudioTracks()
for track in tracks {
    print("Track: \(track.displayName) (Language: \(track.language ?? "unknown"))")
}

// Switch to a specific track by stream index
let targetStreamIndex = tracks.first { $0.language == "jpn" }?.streamIndex
try await decoder.switchAudioTrack(to: targetStreamIndex!)

decoder.close()
```

#### Extracting Cover Images

MKV and other containers can include embedded cover art (common for movies/anime):

```swift
let decoder = try VideoDecoder(url: videoURL)

if let coverData = decoder.extractCoverImage() {
    // coverData is JPEG, PNG, or BMP image data
    let image = NSImage(data: coverData)
}

decoder.close()
```

#### Generating Thumbnails

You can use the `AVSystemVideoRenderer` helper to convert video frames (including complex Dolby Vision frames) to images:

```swift
let decoder = try VideoDecoder(url: videoURL)

// Seek to 10% into the video for a representative frame
let seekTime = decoder.videoInfo.duration * 0.1
try await decoder.seek(to: seekTime, accurate: true)

// Decode one frame
if let packet = await decoder.demuxNextPacket() {
    let frames = await decoder.decodePacket(packet)
    
    for frame in frames {
        if case .video(let videoFrame) = frame {
            // Convert to CGImage (handles DoVi -> HDR10 conversion automatically)
            if let cgImage = AVSystemVideoRenderer.createCGImage(from: videoFrame) {
                 let nsImage = NSImage(cgImage: cgImage, size: CGSize(width: 320, height: 180))
                 // Use the thumbnail...
            }
            break
        }
    }
}

decoder.close()
```

---

### HDR Playback

VidCore leverages macOS's native EDR (Extended Dynamic Range) capabilities by integrating directly with `AVSampleBufferDisplayLayer`. This ensures power-efficient, accurate HDR playback that matches the system's own media handling.

#### System-Integrated Rendering

VidCore hands frame data directly to the OS compositor when possible:

- **HDR10 (PQ)**: Passed as 10-bit buffers with BT.2020 primaries and SMPTE ST 2084 transfer function. macOS handles tone mapping to the display's capabilities.
- **HLG**: Passed as 10-bit HLG buffers. macOS handles the OETF/OOTF processing.
- **Dynamic HDR metadata**: Automatically passed to AVSBDL where supported (DoVi Profiles 5, 8.4 on iOS and macOS, possibly also Profile 8.1 and HDR10+ on tvOS)
- **SDR**: Standard Rec.709 handling.

This approach provides:
- **Perfect Color Matching**: Identical to QuickTime Player and Safari.
- **Power Efficiency**: Uses the dedicated hardware compositor.

#### Automatic HDR Detection

You can inspect the stream's HDR capabilities via `VideoInfo`:

```swift
let decoder = try VideoDecoder(url: videoURL)

if decoder.videoInfo.isHDR {
    print("HDR Content Detected!")
    print("Bit Depth: \(decoder.videoInfo.bitsPerComponent)")      // 10-bit
    
    if decoder.videoInfo.isDolbyVision {
        print("Dolby Vision Profile: \(decoder.videoInfo.doviProfile ?? 0)")
    } else {
        print("Transfer Function: \(decoder.videoInfo.transferFunctionName)") // PQ / HLG
    }
}
```

---

## API Reference

### VideoPlayer

High-level playback orchestrator with A/V sync and state management.

| Property/Method | Description |
|-----------------|-------------|
| `init(buffers:)` | Create player with buffer configuration (`.auto`, `.software`, `.hardware`, or `.custom`) |
| `init(url:buffers:)` | Create and immediately load video |
| `load(url:)` | Load a video file (async, throws) |
| `play()` | Start or resume playback |
| `pause()` | Pause playback |
| `togglePlayPause()` | Toggle between play and pause |
| `toggleMute()` | Toggle mute state |
| `seek(to:accurate:)` | Seek to timestamp (async) |
| `selectAudioTrack(at:)` | Select audio track by index (async) |
| `close()` | Release all resources (async) |

### Buffer Configuration

The `Buffers` enum configures packet queue sizes:

```swift
public enum Buffers {
    case auto           // Automatically choose based on hardware acceleration
    case software       // Optimized for software decoding
    case hardware       // Optimized for hardware passthrough rendering
    case custom(frameBuffer: Int, packetQueue: Int)  // Manual sizes
}
```

**Usage:**

```swift
// Automatic selection (recommended)
let player = VideoPlayer()

// Force software decoding buffers
let player = VideoPlayer(buffers: .software)

// Custom sizes for specific use cases
let player = VideoPlayer(buffers: .custom(frameBuffer: 3, packetQueue: 16))
```

### PlaybackState

```swift
enum PlaybackState {
    case idle       // Initial state, no video loaded
    case loading    // Video is being loaded
    case ready      // Loaded, ready to play
    case playing    // Currently playing
    case paused     // Paused
    case seeking    // Seek in progress
    case finished   // Playback completed
    case error(VideoPlayerError)
}
```

### VideoPlayerError

```swift
enum VideoPlayerError: Error, Equatable, LocalizedError, Sendable {
    case fileNotFound
    case decoderInitFailed(String)
    case unsupportedFormat
    case decodingFailed(String)
    case seekFailed
}
```

### VidPlayer

SwiftUI view for displaying video with optional overlay.

```swift
// Basic
VidPlayer(player: VideoPlayer)

// With overlay
VidPlayer(player: VideoPlayer) { OverlayView() }

// With options
VidPlayer(player: VideoPlayer, showsBuiltInControls: Bool, allowsDebugMenu: Bool, overlay: () -> Overlay)
```

**Parameters:**
- `player`: The `VideoPlayer` instance to display
- `showsBuiltInControls`: Show built-in loading/error/finished UI (default: `true`)
- `allowsDebugMenu`: Enable right-click context menu to toggle debug overlay (default: `false`)
- `overlay`: Custom content to display over the video

#### Debug Overlay

Enable the debug overlay to inspect video playback in real-time. When enabled (via `allowsDebugMenu: true`), right-click on the video to toggle the debug display:

| Category | Information |
|----------|-------------|
| **Video** | Resolution, frame rate, codec, hardware acceleration |
| **Format** | Pixel format, bit depth |
| **Color** | Transfer function, primaries, color space, range |
| **HDR** | HDR status, Dolby Vision profile |
| **Audio** | Codec, sample rate, channel count |
| **A/V Sync** | Current drift, dropped frames, queue health |

### VideoDecoder

Low-level decoder with split demux/decode pipeline.

| Method | Description |
|--------|-------------|
| `init(url:)` | Initialize decoder (throws) |
| `demuxNextPacket()` | Get next packet from container (async) |
| `decodePacket(_:)` | Decode packet to frames (async) |
| `seek(to:accurate:)` | Seek to timestamp (async, throws) |
| `flushVideoDecoder()` | Signal end of stream (async) |
| `drainVideoFrame()` | Get remaining buffered frames (async) |
| `extractCoverImage()` | Extract embedded cover art (JPEG/PNG) from container |
| `getAudioTracks()` | Get available audio tracks |
| `switchAudioTrack(to:)` | Switch to different audio track |
| `close()` | Release resources |
| `videoInfo` | Video metadata |

**Static Methods:**
| Method | Description |
|--------|-------------|
| `willUseHardwareAcceleration(for:)` | Pre-detect if hardware acceleration will be used for a URL |

### VideoInfo

Video stream metadata with color information and HDR detection.

| Property | Type | Description |
|----------|------|-------------|
| `width` | `Int` | Width in pixels |
| `height` | `Int` | Height in pixels |
| `frameRate` | `Double` | Frame rate (fps) |
| `duration` | `Double` | Duration in seconds |
| `codecName` | `String` | Codec identifier (e.g., "h264") |
| `isHardwareAccelerated` | `Bool` | Using passthrough sample buffers |
| `isHDR` | `Bool` | Whether content is HDR (PQ or HLG) |
| `isDolbyVision` | `Bool` | Whether content is Dolby Vision |
| `colorPrimaries` | `Int` | Color primaries (1=BT.709, 9=BT.2020) |
| `colorTransfer` | `Int` | Transfer function (1=BT.709, 16=PQ, 18=HLG) |
| `colorSpace` | `Int` | YUV color matrix (1=BT.709, 9=BT.2020nc) |
| `colorRange` | `Int` | Video range (1=limited/16-235, 2=full/0-255) |
| `bitsPerComponent` | `Int` | Bit depth (8, 10, or 12 bits) |
| `decoderName` | `String?` | Specific decoder used (e.g., "SampleBufferBuilder") |
| `decoderDescription` | `String?` | Description of the decoder implementation |
| `maxContentLightLevel` | `UInt?` | MaxCLL in nits, nil if not present |
| `maxFrameAverageLightLevel` | `UInt?` | MaxFALL in nits, nil if not present |
| `masteringDisplayMaxLuminance` | `Float?` | Mastering display max luminance in nits |
| `masteringDisplayMinLuminance` | `Float?` | Mastering display min luminance in nits |
| `audioCodecName` | `String?` | Audio codec (e.g., "aac", "opus"), nil if no audio |
| `audioSampleRate` | `Int?` | Audio sample rate in Hz (e.g., 48000) |
| `audioChannels` | `Int?` | Number of audio channels |
| `contentPeakNits` | `Float` | Computed: recommended content peak for tone mapping |
| `transferFunctionName` | `String` | Computed: human-readable transfer function |
| `colorPrimariesName` | `String` | Computed: human-readable color primaries |
| `colorSpaceName` | `String` | Computed: human-readable color space |
| `audioTracks` | `[AudioTrackInfo]` | All available audio tracks |
| `containerName` | `String` | Container format name (e.g., "mov,mp4,m4a") |
| `didSynthesizeExtradata` | `Bool` | Whether extradata was synthesized for hardware decoding |

### VideoFrame

A decoded video frame with pixel data and timing information.

| Property | Type | Description |
|----------|------|-------------|
| `pixelBuffer` | `CVPixelBuffer` | Raw pixel data (NV12, I420, P010, or BGRA) |
| `presentationTime` | `Double` | PTS in seconds |
| `isHDR` | `Bool` | Whether frame contains HDR content |
| `colorTransfer` | `Int` | Color transfer characteristics (1=BT.709, 16=PQ, 18=HLG) |
| `doviProfile` | `Int` | Dolby Vision Profile ID (e.g., 5, 8), 0 if not present |

**Supported Pixel Formats:**
- **NV12**: 8-bit bi-planar (Standard, Hardware)
- **I420**: 8-bit tri-planar (Software)
- **P010**: 10-bit bi-planar (HDR Hardware)
- **BGRA**: 8-bit packed (Fallback)

### AudioTrackInfo

Information about an available audio track.

| Property | Type | Description |
|----------|------|-------------|
| `id` | `Int` | Unique identifier |
| `streamIndex` | `Int` | Stream index in container |
| `language` | `String?` | Language code (e.g., "eng", "jpn") |
| `title` | `String?` | Track title (e.g., "Director's Commentary") |
| `codecName` | `String` | Audio codec name (e.g., "aac", "opus") |
| `sampleRate` | `Int` | Sample rate in Hz (e.g., 48000) |
| `channels` | `Int` | Number of channels |
| `isDefault` | `Bool` | Whether this is the default track |
| `displayName` | `String` | Full display name (computed) |
| `shortDisplayName` | `String` | Short display name for UI (computed) |

### AVSystemVideoRenderer

A SwiftUI view wrapper for `AVSampleBufferDisplayLayer` that provides direct system integration for high-performance rendering.

```swift
// Render a video frame in SwiftUI
AVSystemVideoRenderer(currentFrame: player.currentFrame)

// Generate a thumbnail (handles Dolby Vision Profile 5 automatically)
if let cgImage = AVSystemVideoRenderer.createCGImage(from: videoFrame) {
    let thumbnail = NSImage(cgImage: cgImage, size: size)
}
```

### PlayerDebugStats

Real-time playback statistics for debugging and monitoring.

| Property | Type | Description |
|----------|------|-------------|
| `packetQueueCount` | `Int` | Current packets in queue |
| `packetQueueMax` | `Int` | Maximum queue size |
| `videoRendererReady` | `Bool` | Whether the video renderer is ready for more data |
| `audioRendererReady` | `Bool` | Whether the audio renderer is ready for more data |
| `audioBackend` | `String` | Active audio backend (`System` or `AudioEngine`) |
| `lastVideoPTS` | `Double` | Last video presentation timestamp |
| `lastAudioPTS` | `Double` | Last audio presentation timestamp |
| `decoderName` | `String` | Name of active decoder |
| `syncRate` | `Double` | Current AVSampleBufferRenderSynchronizer playback rate |

You can detect which audio backend is active by checking the `SystemAudioRenderer` flags when you construct a player:

```swift
let usesSystemAudio = SystemAudioRenderer.isSupportedInCurrentProcess
  && !SystemAudioRenderer.isForceFallbackEnabled
```
