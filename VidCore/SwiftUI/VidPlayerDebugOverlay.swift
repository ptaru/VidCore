//
//  VidPlayerDebugOverlay.swift
//  VidCore
//
//  Debug overlay for VidPlayer
//

import CoreVideo
import SwiftUI

/// Debug overlay showing comprehensive video info (right-click to toggle)
struct VidPlayerDebugOverlay: View {
  let frame: VideoFrame
  let videoInfo: VideoInfo?
  let debugStats: PlayerDebugStats?
  let selectedAudioTrackIndex: Int
  let onAudioTrackSelected: ((Int) -> Void)?
  let selectedSubtitleTrackIndex: Int
  let onSubtitleTrackSelected: ((Int) -> Void)?
  let playbackRate: Double
  let onPlaybackRateChanged: ((Double) -> Void)?
  let currentTime: Double

  @State private var isAudioTracksExpanded = true
  @State private var isSubtitleTracksExpanded = true

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      pipelineTimingColumn

      Divider().background(Color.white.opacity(0.3))

      videoColorColumn

      Divider().background(Color.white.opacity(0.3))

      audioSubtitleMetadataColumn
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

  private var pipelineTimingColumn: some View {
    VStack(alignment: .leading, spacing: 4) {
      header("Pipeline & Timing")

      if let info = videoInfo {
        debugRow("Container", info.containerName)
        debugRow("Codec", info.codecName.uppercased())
        debugRow(
          "HW Path",
          info.isHardwareAccelerated ? "Active" : "Software",
          color: info.isHardwareAccelerated ? .green : .orange
        )
        if info.didSynthesizeExtradata {
          debugRow("Extradata", "Synthesized", color: .green)
        }
      }

      if let stats = debugStats {
        Group {
          debugRow("Decoder", stats.decoderName)

          // Buffer Health
          let pqPct = Double(stats.packetQueueCount) / Double(max(1, stats.packetQueueMax)) * 100

          // Pad current count based on max value digits to prevent jumping
          let pqWidth = String(stats.packetQueueMax).count
          let pqLabel = String(
            format: "%\(pqWidth)d/\(stats.packetQueueMax)", stats.packetQueueCount)

          debugBar("Packet Queue", percent: pqPct, label: pqLabel)
          debugRow(
            "Video Renderer",
            stats.videoRendererReady ? "Ready" : "Backpressure",
            color: stats.videoRendererReady ? .green : .orange
          )
          debugRow(
            "Audio Renderer",
            stats.audioRendererReady ? "Ready" : "Backpressure",
            color: stats.audioRendererReady ? .green : .orange
          )
          debugRow("Audio Path", stats.audioBackend)
        }
      }

      Divider().background(Color.white.opacity(0.3))

      Group {
        debugRow("PTS", String(format: "%.3fs", frame.presentationTime))
        debugRow("Clock", String(format: "%.3fs", currentTime))
        if let stats = debugStats {
          debugRow("Clock Rate", String(format: "%.2fx", stats.syncRate))
          debugRow("Last PTS", String(format: "%.3fs", stats.lastVideoPTS))
        }
        let drift = currentTime - frame.presentationTime
        debugRow("Clock Drift", String(format: "%+.3fs", drift))
        if let info = videoInfo {
          let frameVal = frame.presentationTime * info.frameRate
          let frameNumberStr = frameVal.isFinite ? "\(Int(frameVal))" : "Unknown"
          debugRow("Frame #", frameNumberStr)
        }
        HStack {
          Text("Speed:")
            .foregroundColor(.gray)
          Text(String(format: "%.2fx", playbackRate))
            .foregroundColor(.white)
            .frame(width: 40, alignment: .leading)

          Slider(
            value: Binding(
              get: { playbackRate },
              set: { onPlaybackRateChanged?($0) }
            ), in: 0.25...4.0, step: 0.25
          )
          .controlSize(.mini)
          .frame(width: 100)
        }
      }
    }
  }

  private var videoColorColumn: some View {
    VStack(alignment: .leading, spacing: 4) {
      header("Video & Color")

      if let info = videoInfo {
        debugRow("Resolution", "\(info.width)×\(info.height)")
        debugRow("Frame Rate", String(format: "%.2f fps", info.frameRate))
        debugRow("Duration", String(format: "%.2fs", info.duration))
        debugRow("Aspect", String(format: "%.3f", info.displayAspectRatio))
      }

      let pixelInfo = pixelFormatInfo(from: frame.pixelBuffer)
      debugRow("Pixel Format", pixelInfo.format)
      debugRow("Bit Depth", pixelInfo.bitDepth)

      Divider().background(Color.white.opacity(0.3))

      if let info = videoInfo {
        debugRow("Transfer", "\(info.transferFunctionName) (\(info.colorTransfer))")
        debugRow("Primaries", "\(info.colorPrimariesName) (\(info.colorPrimaries))")
        debugRow("Matrix", "\(info.colorSpaceName) (\(info.colorSpace))")
        debugRow("Range", "\(info.colorRange == 2 ? "Full" : "Limited") (\(info.colorRange))")

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

          if frame.ambientLightMetadata != nil {
            debugRow("Ambient Light", "Present", color: .green)
          }
        } else {
          debugRow("SDR", "Active")
        }
      }
    }
  }

  private var audioSubtitleMetadataColumn: some View {
    VStack(alignment: .leading, spacing: 4) {
      header("Audio, Subtitles & Metadata")

      if let info = videoInfo {
        if let audioFormat = audioFormatSummary(from: info) {
          debugRow("Audio Format", audioFormat)
        }
      }

      if let info = videoInfo, !info.audioTracks.isEmpty {
        trackSectionHeader(
          title: "Audio Tracks (\(info.audioTracks.count))",
          isExpanded: isAudioTracksExpanded,
          onToggle: { isAudioTracksExpanded.toggle() }
        )
        if isAudioTracksExpanded {
          trackList(
            items: info.audioTracks,
            selectedIndex: selectedAudioTrackIndex,
            onSelect: { onAudioTrackSelected?($0) },
            displayName: { $0.displayName },
            isDefault: { $0.isDefault }
          )
        }
        Divider().background(Color.white.opacity(0.3))
      } else if let info = videoInfo, info.audioTracks.isEmpty {
        debugRow("Audio", "None", color: .gray)
        Divider().background(Color.white.opacity(0.3))
      }

      if let info = videoInfo, !info.subtitleTracks.isEmpty {
        trackSectionHeader(
          title: "Subtitles (\(info.subtitleTracks.count))",
          isExpanded: isSubtitleTracksExpanded,
          onToggle: { isSubtitleTracksExpanded.toggle() }
        )
        if isSubtitleTracksExpanded {
          trackList(
            items: info.subtitleTracks,
            selectedIndex: selectedSubtitleTrackIndex,
            onSelect: { onSubtitleTrackSelected?($0) },
            displayName: { $0.displayName },
            isDefault: { $0.isDefault },
            includeNoneOption: true,
            noneSelected: selectedSubtitleTrackIndex == -1,
            onSelectNone: { onSubtitleTrackSelected?(-1) }
          )
        }
        Divider().background(Color.white.opacity(0.3))
      } else if let info = videoInfo, info.subtitleTracks.isEmpty {
        debugRow("Subtitles", "None", color: .gray)
        Divider().background(Color.white.opacity(0.3))
      }

    }
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

  private func trackSectionHeader(title: String, isExpanded: Bool, onToggle: @escaping () -> Void)
    -> some View
  {
    Button(action: onToggle) {
      HStack {
        Text(title)
          .fontWeight(.bold)
          .foregroundColor(.white.opacity(0.9))
        Spacer()
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption)
          .foregroundColor(.gray)
      }
    }
    .buttonStyle(PlainButtonStyle())
  }

  private func trackList<Item: Identifiable>(
    items: [Item],
    selectedIndex: Int,
    onSelect: @escaping (Int) -> Void,
    displayName: @escaping (Item) -> String,
    isDefault: @escaping (Item) -> Bool,
    includeNoneOption: Bool = false,
    noneSelected: Bool = false,
    onSelectNone: (() -> Void)? = nil
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if includeNoneOption {
          Button(action: { onSelectNone?() }) {
            HStack {
              Text(noneSelected ? "●" : "○")
                .foregroundColor(noneSelected ? .green : .gray)
                .font(.system(size: 8))
              Text("None")
                .foregroundColor(noneSelected ? .green : .white)
                .fontWeight(noneSelected ? .bold : .regular)
              Spacer()
            }
          }
          .buttonStyle(PlainButtonStyle())
          .padding(.leading, 8)
          .padding(.vertical, 1)
        }

        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
          let isSelected = index == selectedIndex
          Button(action: { onSelect(index) }) {
            HStack {
              Text(isSelected ? "●" : "○")
                .foregroundColor(isSelected ? .green : .gray)
                .font(.system(size: 8))
              let name = displayName(item)
              Text(name)
                .foregroundColor(isSelected ? .green : .white)
                .fontWeight(isSelected ? .bold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(name)
              if isDefault(item) {
                Text("Default")
                  .font(.system(size: 9))
                  .foregroundColor(.yellow)
                  .padding(.horizontal, 4)
                  .padding(.vertical, 1)
                  .background(Color.yellow.opacity(0.2))
                  .cornerRadius(2)
              }
              Spacer()
            }
          }
          .buttonStyle(PlainButtonStyle())
          .padding(.leading, 8)
          .padding(.vertical, 1)
        }
      }
    }
    .frame(maxWidth: 300, maxHeight: 200)
  }

  private func audioFormatSummary(from info: VideoInfo) -> String? {
    var parts: [String] = []
    if let codec = info.audioCodecName, !codec.isEmpty {
      parts.append(codec.uppercased())
    }
    if let rate = info.audioSampleRate, rate > 0 {
      parts.append("\(rate) Hz")
    }
    if let channels = info.audioChannels, channels > 0 {
      parts.append("\(channels)ch")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " • ")
  }

  /// Returns pixel format name and bit depth from CVPixelBuffer (or Compressed status)
  private func pixelFormatInfo(from pixelBuffer: CVPixelBuffer?) -> (
    format: String, bitDepth: String
  ) {
    guard let pixelBuffer = pixelBuffer else {
      return ("Compressed (A/V Layer)", "See Codec")
    }

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
        Character(UnicodeScalar(format & 0xFF)!),
      ]
      return (String(chars), "Unknown")
    }
  }

}
