//
//  ASSSubtitlePipeline.swift
//  VidCore
//
//  Coordinates ASS/SSA subtitle rendering via libass.
//

import Foundation

final class ASSSubtitlePipeline {
  let renderer: LibASSRenderer?

  private var currentSubtitleTrackIsASSDetected = false
  private var assHeaderConfigured = false
  private let videoInfo: VideoInfo

  init(videoInfo: VideoInfo) {
    self.videoInfo = videoInfo
    self.renderer = LibASSRenderer()
  }

  func configureHeaderIfNeeded(from config: [String: Any]) {
    guard !assHeaderConfigured,
      let extradata = config["subtitleExtradata"] as? Data,
      let header = String(data: extradata, encoding: .utf8),
      isASSHeader(header)
    else {
      return
    }

    renderer?.configure(withHeader: header)
    assHeaderConfigured = true
  }

  func reset(flush: Bool) {
    currentSubtitleTrackIsASSDetected = false
    assHeaderConfigured = false
    if flush {
      renderer?.flush()
    }
  }

  func processASS(text: String, packetData: Data, pts: Double, duration: Double) {
    currentSubtitleTrackIsASSDetected = true
    ensureDefaultHeaderIfNeeded()

    let data = text.data(using: .utf8) ?? packetData
    renderer?.processPacket(data, pts: pts, duration: duration)
  }

  func isASSActive(for demuxer: FFmpegDemuxer?) -> Bool {
    if currentSubtitleTrackIsASSDetected {
      return true
    }
    guard let demuxer else { return false }
    let index = demuxer.selectedSubtitleStreamIndex()
    if index < 0 { return false }
    if let tracks = demuxer.getSubtitleTracks(),
      let track = tracks.first(where: { $0.streamIndex == index })
    {
      return track.codecName == "ass" || track.codecName == "ssa"
    }
    return false
  }

  private func ensureDefaultHeaderIfNeeded() {
    guard !assHeaderConfigured else { return }
    renderer?.configure(withHeader: defaultASSHeader())
    assHeaderConfigured = true
  }

  private func isASSHeader(_ header: String) -> Bool {
    return header.contains("[Script Info]") || header.contains("ScriptType:")
      || header.contains("[V4+ Styles]") || header.contains("[Events]")
  }

  private func defaultASSHeader() -> String {
    // We use a fixed virtual resolution for PlayResY (720) to ensure
    // consistent font sizing regardless of the video's actual resolution.
    let playResY = 720
    let aspectRatio =
      videoInfo.displayAspectRatio.isFinite ? videoInfo.displayAspectRatio : (16.0 / 9.0)
    let playResX = Int(Double(playResY) * aspectRatio)

    return """
      [Script Info]
      ScriptType: v4.00+
      PlayResX: \(playResX)
      PlayResY: \(playResY)
      ScaledBorderAndShadow: yes

      [V4+ Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
      Style: Default,Arial,36,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,80,1

      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      """
  }
}
