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

  @State private var isAttachmentsExpanded = false
  @State private var isAudioTracksExpanded = true
  @State private var isSubtitleTracksExpanded = true

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      // Left Column: Pipeline & Timing
      VStack(alignment: .leading, spacing: 4) {
        header("Pipeline & Timing")

        // Pipeline Stats
        if let info = videoInfo {
          debugRow("Container", info.containerName)
          debugRow("Codec", info.codecName.uppercased())
          if info.didSynthesizeExtradata {
            debugRow("Extradata", "Synthesized", color: .green)
          }
        }

        if let stats = debugStats {
          Group {
            debugRow("State", "Playing")  // Dynamic in future
            debugRow("Decoder", stats.decoderName)
            debugRow("Clock Rate", String(format: "%.2fx", stats.syncRate))
            if stats.keyframeCount > 0 {
              debugRow("Keyframes", "\(stats.keyframeCount)")
            } else {
              debugRow("Keyframes", "Indexing...", color: .gray)
            }

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

        Divider().background(Color.white.opacity(0.3))

        // Timing
        Group {
          debugRow("PTS", String(format: "%.3fs", frame.presentationTime))
          if let stats = debugStats {
            debugRow("Audio PTS", String(format: "%.3fs", stats.lastAudioPTS))
          }
          if let info = videoInfo {
            let frameNumber = Int(frame.presentationTime * info.frameRate)
            debugRow("Frame #", "\(frameNumber)")
          }
          // Speed Control
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
        }

        let pixelInfo = pixelFormatInfo(from: frame.pixelBuffer)
        debugRow("Pixel Format", pixelInfo.format)
        debugRow("Bit Depth", pixelInfo.bitDepth)

        Divider().background(Color.white.opacity(0.3))

        // Color Info
        if let info = videoInfo {
          debugRow("Transfer", "\(info.transferFunctionName) (\(info.colorTransfer))")
          debugRow("Primaries", "\(info.colorPrimariesName) (\(info.colorPrimaries))")
          debugRow("Matrix", "\(info.colorSpaceName) (\(info.colorSpace))")
          debugRow("Range", "\(info.colorRange == 2 ? "Full" : "Limited") (\(info.colorRange))")

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

      // Right Column: Audio, Subtitles & Metadata
      VStack(alignment: .leading, spacing: 4) {
        header("Audio, Subtitles & Metadata")

        // Audio Track Selector
        if let info = videoInfo, !info.audioTracks.isEmpty {
          Button(action: { isAudioTracksExpanded.toggle() }) {
            HStack {
              Text("Audio Tracks (\(info.audioTracks.count))")
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.9))
              Spacer()
              Image(systemName: isAudioTracksExpanded ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundColor(.gray)
            }
          }
          .buttonStyle(PlainButtonStyle())

          if isAudioTracksExpanded {
            ScrollView {
              VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(info.audioTracks.enumerated()), id: \.element.id) { index, track in
                  let isSelected = index == selectedAudioTrackIndex
                  Button(action: {
                    onAudioTrackSelected?(index)
                  }) {
                    HStack {
                      Text(isSelected ? "●" : "○")
                        .foregroundColor(isSelected ? .green : .gray)
                        .font(.system(size: 8))
                      Text(track.displayName)
                        .foregroundColor(isSelected ? .green : .white)
                        .fontWeight(isSelected ? .bold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(track.displayName)
                      if track.isDefault {
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

          Divider().background(Color.white.opacity(0.3))
        } else if let info = videoInfo, info.audioTracks.isEmpty {
          debugRow("Audio", "None", color: .gray)
          Divider().background(Color.white.opacity(0.3))
        }

        // Subtitle Track Selector
        if let info = videoInfo, !info.subtitleTracks.isEmpty {
          Button(action: { isSubtitleTracksExpanded.toggle() }) {
            HStack {
              Text("Subtitles (\(info.subtitleTracks.count))")
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.9))
              Spacer()
              Image(systemName: isSubtitleTracksExpanded ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundColor(.gray)
            }
          }
          .buttonStyle(PlainButtonStyle())

          if isSubtitleTracksExpanded {
            ScrollView {
              VStack(alignment: .leading, spacing: 2) {
                // "None" option
                Button(action: {
                  onSubtitleTrackSelected?(-1)
                }) {
                  HStack {
                    Text(selectedSubtitleTrackIndex == -1 ? "●" : "○")
                      .foregroundColor(selectedSubtitleTrackIndex == -1 ? .green : .gray)
                      .font(.system(size: 8))
                    Text("None")
                      .foregroundColor(selectedSubtitleTrackIndex == -1 ? .green : .white)
                      .fontWeight(selectedSubtitleTrackIndex == -1 ? .bold : .regular)
                    Spacer()
                  }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
                .padding(.vertical, 1)

                ForEach(Array(info.subtitleTracks.enumerated()), id: \.element.id) { index, track in
                  let isSelected = index == selectedSubtitleTrackIndex
                  Button(action: {
                    onSubtitleTrackSelected?(index)
                  }) {
                    HStack {
                      Text(isSelected ? "●" : "○")
                        .foregroundColor(isSelected ? .green : .gray)
                        .font(.system(size: 8))
                      Text(track.displayName)
                        .foregroundColor(isSelected ? .green : .white)
                        .fontWeight(isSelected ? .bold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(track.displayName)
                      if track.isDefault {
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

          Divider().background(Color.white.opacity(0.3))
        } else if let info = videoInfo, info.subtitleTracks.isEmpty {
          debugRow("Subtitles", "None", color: .gray)
          Divider().background(Color.white.opacity(0.3))
        }

        // Attachments
        Button(action: { isAttachmentsExpanded.toggle() }) {
          HStack {
            Text("Attachments")
              .fontWeight(.bold)
              .foregroundColor(.white.opacity(0.9))
            Spacer()
            Image(systemName: isAttachmentsExpanded ? "chevron.down" : "chevron.right")
              .font(.caption)
              .foregroundColor(.gray)
          }
        }
        .buttonStyle(PlainButtonStyle())

        if isAttachmentsExpanded {
          let attachments = getAttachments(from: frame.pixelBuffer)
          if attachments.isEmpty {
            Text("No attachments")
              .foregroundColor(.gray)
              .padding(.leading, 8)
          } else {
            ForEach(attachments, id: \.0) { key, value in
              VStack(alignment: .leading, spacing: 2) {
                Text(key)
                  .foregroundColor(.gray)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Text(value)
                  .foregroundColor(.white)
                  .lineLimit(2)
              }
              .padding(.leading, 8)
              .padding(.bottom, 4)
            }
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
  private func pixelFormatInfo(from pixelBuffer: CVPixelBuffer) -> (
    format: String, bitDepth: String
  ) {
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

  /// Extracts attachments from CVPixelBuffer as key-value pairs
  private func getAttachments(from pixelBuffer: CVPixelBuffer) -> [(String, String)] {
    guard let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any]
    else {
      return []
    }

    return attachments.sorted(by: { $0.key < $1.key }).map { key, value in
      return (key, String(describing: value))
    }
  }
}
