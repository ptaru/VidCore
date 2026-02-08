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

    /// Creates a new subtitle view.
    /// - Parameter subtitle: The subtitle frame to display, or nil to hide subtitles.
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
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 60)
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

                case .image(let imageBox):
                    Image(decorative: imageBox.image, scale: 1.0)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .transition(.opacity)
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

#Preview {
    ZStack {
        Color.blue.opacity(0.3)
        SubtitleView(
            subtitle: SubtitleFrame(
                content: .text("This is a centered subtitle\nraised slightly higher"), startTime: 0,
                endTime: 5))
    }
    .frame(width: 800, height: 450)
}
