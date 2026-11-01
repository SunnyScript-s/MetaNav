import SwiftUI

/// One place for the colours and text sizes, so the screens stay consistent.
enum Theme {
  static let background = Color(red: 0.031, green: 0.035, blue: 0.039)
  static let surface = Color(red: 0.078, green: 0.086, blue: 0.098)
  static let surfaceRaised = Color(red: 0.110, green: 0.122, blue: 0.137)
  static let stroke = Color(red: 0.157, green: 0.173, blue: 0.192)

  static let primary = Color(red: 0.961, green: 0.969, blue: 0.965)
  static let secondary = Color(red: 0.612, green: 0.647, blue: 0.635)
  static let accent = Color(red: 0.482, green: 0.878, blue: 0.651)
  static let warning = Color(red: 0.976, green: 0.710, blue: 0.353)

  static let corner: CGFloat = 28
}

struct ScreenBackground: View {
  var body: some View {
    ZStack {
      Theme.background
      RadialGradient(
        colors: [Theme.accent.opacity(0.10), .clear],
        center: .top,
        startRadius: 0,
        endRadius: 420
      )
      .ignoresSafeArea()
    }
    .ignoresSafeArea()
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  var filled: Bool = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold, design: .rounded))
      .foregroundStyle(filled ? Theme.background : Theme.primary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 18)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(filled ? Theme.accent : Theme.surfaceRaised)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(filled ? .clear : Theme.stroke, lineWidth: 1)
      )
      .opacity(configuration.isPressed ? 0.75 : 1)
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct StatusPill: View {
  var text: String
  var isLive: Bool

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(isLive ? Theme.accent : Theme.secondary)
        .frame(width: 7, height: 7)
      Text(text)
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(
      Capsule().fill(Theme.surface)
    )
    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
  }
}
