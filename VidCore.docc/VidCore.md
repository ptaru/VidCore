# ``VidCore``

High-performance video decoding and rendering framework for macOS.

## Overview

VidCore provides a modern, asynchronous API for playing video content on macOS. It combines FFmpeg for broad codec support with VideoToolbox hardware acceleration, rendering directly through `AVSampleBufferDisplayLayer` for efficient, power-efficient playback with perfect color accuracy. Full HDR10, HLG, and Dolby Vision Profile 5 support enables wide color gamut and extended dynamic range playback on EDR-capable displays.

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

### SwiftUI Views

- ``VidPlayer``
- ``AVSystemVideoRenderer``

### Playback

- ``VideoPlayer``
- ``PlaybackState``
- ``VideoPlayerError``
- ``PlayerDebugStats``

### Decoding

- ``VideoDecoder``
- ``VideoInfo``
- ``VideoFrame``
- ``DecodedFrame``
- ``AudioTrackInfo``

### Audio

- ``AudioPlayer``

### Buffer Configuration

- ``Buffers``

### Rendering

- ``LayerRenderer``
- ``VideoRendererTarget``

