//
//  SubtitleView.swift
//  VidCore
//
//  Display view for rendering subtitles.
//

import SwiftUI

/// A view that renders the current subtitle frame.
public struct SubtitleView: View {
  let subtitle: SubtitleFrame?

  public init(subtitle: SubtitleFrame?) {
    self.subtitle = subtitle
  }

  public var body: some View {
    if let subtitle = subtitle {
      Group {
        switch subtitle.content {
        case .text(let text):
          if text.isEmpty {
            EmptyView()
          } else {
            let shouldParseASS = subtitle.isASS || text.contains("{\\")
            let parsed = SubtitleParser.parse(text, isASS: shouldParseASS)
            VStack {
              Spacer()
              // Use SubtitleParser to render styled text
              textView(parsed)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                  Color.black.opacity(0.6)
                    .cornerRadius(8)
                )
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                .padding(.bottom, 20)
            }
            .task(id: text) {
              if text.contains("font") || text.contains("&lt;") {
                let colorRunCount = parsed.runs.reduce(into: 0) { count, run in
                  if run.foregroundColor != nil { count += 1 }
                }
                print("[SubtitleView] isASS=\(subtitle.isASS)")
                print("[SubtitleView] raw=\(text)")
                print("[SubtitleView] colorRuns=\(colorRunCount)")
              }
            }
          }

        case .bitmaps(let bitmaps):
          GeometryReader { geometry in
            ForEach(0..<bitmaps.count, id: \.self) { index in
              let bitmap = bitmaps[index]
              if let cgImage = createCGImage(
                from: bitmap.data, width: bitmap.width, height: bitmap.height)
              {

                // dimensions in points based on normalized rect and view size
                let viewWidth = geometry.size.width
                let viewHeight = geometry.size.height

                let frameWidth = bitmap.rect.width * viewWidth
                let frameHeight = bitmap.rect.height * viewHeight
                let frameX = bitmap.rect.minX * viewWidth
                let frameY = bitmap.rect.minY * viewHeight

                Image(decorative: cgImage, scale: 1.0)
                  .resizable()
                  .interpolation(.medium)
                  .aspectRatio(contentMode: .fit)
                  .frame(width: frameWidth, height: frameHeight)
                  // Position is center-based in SwiftUI
                  .position(
                    x: frameX + frameWidth / 2,
                    y: frameY + frameHeight / 2
                  )
              }
            }
          }
        }
      }
      .padding(.bottom, 40)
      .transition(.opacity)
      .animation(.easeInOut(duration: 0.1), value: subtitle.startTime)
    }
  }

  private func textView(_ parsed: AttributedString) -> Text {
    var combined: Text?
    for run in parsed.runs {
      let slice = parsed[run.range]
      var segment = Text(AttributedString(slice))
      segment = segment.foregroundColor(run.foregroundColor ?? .white)
      if let combinedText = combined {
        combined = combinedText + segment
      } else {
        combined = segment
      }
    }
    return combined ?? Text("")
  }

  private func createCGImage(from data: Data, width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let provider = CGDataProvider(data: data as CFData) else { return nil }

    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: bitmapInfo,
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}
