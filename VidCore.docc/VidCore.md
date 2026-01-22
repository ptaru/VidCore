# ``VidCore``

High-performance video decoding and rendering framework for macOS.

## Overview

VidCore provides a modern, asynchronous API for playing video content on macOS. It combines FFmpeg for broad codec support with Metal for efficient, zero-copy GPU rendering. Full HDR10, HLG, and Dolby Vision Profile 5 support enables wide color gamut and extended dynamic range playback on EDR-capable displays.

### Quick Start

The simplest way to play a video in SwiftUI:

```swift
import SwiftUI
import VidCore

struct ContentView: View {
    var body: some View {
        VidPlayer(url: videoURL)
    }
}
```

For more control:

```swift
@State private var player = VideoPlayer()

VidPlayer(player: player)
    .task {
        try? await player.load(url: videoURL)
        player.play()
    }
```

## Topics

### SwiftUI Views

- ``VidPlayer``
- ``MetalVideoRenderer``

### Playback

- ``VideoPlayer``
- ``PlaybackState``
- ``VideoPlayerError``

### Decoding

- ``VideoDecoder``
- ``VideoInfo``
- ``VideoFrame``
- ``DecodedFrame``
- ``DoViMetadata``

### Rendering

- ``RenderingEngine``
- ``ToneMapping``

