# ``VidCore``

High-performance video decoding and rendering framework for macOS.

## Overview

VidCore provides a modern, asynchronous API for playing video content on macOS. It combines FFmpeg for broad codec support with hardware-accelerated rendering, rendering directly through `AVSampleBufferDisplayLayer` for efficient, power-efficient playback with perfect color accuracy. Full HDR10, HLG, and Dolby Vision Profile 5 support enables wide color gamut and extended dynamic range playback on EDR-capable displays.

### Quick Start

The simplest way to play a video in SwiftUI:

```swift
import SwiftUI
import VidCore

struct ContentView: View {
    let videoURL: URL
    
    var body: some View {
        VidPlayer(url: videoURL, autoPlay: true)
            .edgesIgnoringSafeArea(.all)
    }
}
```

For more control with custom UI:

```swift
@State private var player = VideoPlayer()

VidPlayer(player: player, showsBuiltInControls: false) {
    CustomControlsOverlay(player: player)
}
.task {
    try? await player.load(url: videoURL)
    player.play()
}
```

## Topics

> Note: In app extension contexts (e.g. Quick Look), VidCore falls back to `AVAudioEngine` for audio playback. This is best-effort and may not be sample-accurate.

### SwiftUI Views

- ``VidPlayer``
- ``AVSystemVideoRenderer``

### Playback

- ``VideoPlayer``
- ``PlaybackState``
- ``VideoPlayerError``
- ``PlayerDebugStats``
- ``PlaybackClock``
- ``SystemAudioRenderer``
- ``AudioEngineRenderer``
- ``AudioRendering``

### Audio Routing

`AudioRendering` abstracts the audio output backend. On macOS app extensions (e.g. Quick Look), VidCore falls back to ``AudioEngineRenderer`` (AVAudioEngine) because ``SystemAudioRenderer`` (AVSampleBufferAudioRenderer) is unavailable. This fallback is best-effort and may not be sample-accurate.

To detect which audio backend is active:

```swift
let usesSystemAudio = SystemAudioRenderer.isSupportedInCurrentProcess
  && !SystemAudioRenderer.isForceFallbackEnabled
```

For testing the fallback in a normal app, set `VIDCORE_FORCE_AUDIO_ENGINE=1` in the environment.

### Decoding

- ``VideoDecoder``
- ``VideoInfo``
- ``VideoFrame``
- ``DecodedFrame``
- ``AudioTrackInfo``

### Buffer Configuration

- ``Buffers``

### Rendering

- ``LayerRenderer``
- ``VideoRendererTarget``
