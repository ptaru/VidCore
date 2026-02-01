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
            VStack {
              Spacer()
              Text(text)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
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
          }

        case .bitmap(let data, let width, let height, let rect):
          GeometryReader { geometry in
            // Create image using RAW pixel dimensions
            if let cgImage = createCGImage(from: data, width: width, height: height) {

              // dimensions in points based on normalized rect and view size
              let viewWidth = geometry.size.width
              let viewHeight = geometry.size.height

              let frameWidth = rect.width * viewWidth
              let frameHeight = rect.height * viewHeight
              let frameX = rect.minX * viewWidth
              let frameY = rect.minY * viewHeight

              Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: frameWidth, height: frameHeight)
                // Position is center-based in SwiftUI, so we need to offset from top-left (frameX, frameY)
                .position(
                  x: frameX + frameWidth / 2,
                  y: frameY + frameHeight / 2
                )
            }
          }
        }
      }
      .padding(.bottom, 40)
      .transition(.opacity)
      .animation(.easeInOut(duration: 0.1), value: subtitle.startTime)
    }
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
