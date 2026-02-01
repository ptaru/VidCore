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

        case .bitmap(let data, let width, let height):
          // Placeholder for bitmap subtitles
          // In a real implementation, we would create an Image from the Data
          if let uiImage = NSImage(data: data) {
            Image(nsImage: uiImage)
              .resizable()
              .aspectRatio(contentMode: .fit)
          } else {
            EmptyView()
          }
        }
      }
      .padding(.bottom, 40)
      .transition(.opacity)
      .animation(.easeInOut(duration: 0.1), value: subtitle.startTime)
    }
  }
}
