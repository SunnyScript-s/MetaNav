import SwiftUI

/// The whole app is one screen that changes with what the wearer is doing.
struct RootView: View {
  @ObservedObject var model: NavigationController

  var body: some View {
    ZStack {
      ScreenBackground()

      VStack(spacing: 0) {
        header
        Spacer(minLength: 0)
        content
        Spacer(minLength: 0)
        footer
      }
      .padding(.horizontal, 24)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .preferredColorScheme(.dark)
  }

  private var header: some View {
    HStack {
      StatusPill(text: model.status, isLive: model.isListening || model.isSpeaking)
      Spacer()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .navigating:
      NavigatingView(model: model)
    case .choosing:
      ChoosingView(model: model)
    case .failed(let message):
      ErrorView(message: message, model: model)
    case .searching:
      WorkingView(title: "Finding your route", subtitle: model.heard)
    case .idle:
      HomeView(model: model)
    }
  }

  private var footer: some View {
    Group {
      if model.phase == .idle, model.linkState == .ready {
        Text("Say “navigate to”, then a place.")
          .font(.system(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(Theme.secondary)
      }
    }
  }
}

// MARK: - Home

private struct HomeView: View {
  @ObservedObject var model: NavigationController
  @State private var pulse = false

  var body: some View {
    VStack(spacing: 28) {
      if model.linkState == .ready {
        listeningRing
        VStack(spacing: 8) {
          Text("Listening")
            .font(.system(size: 32, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.primary)
          Text(model.heard.isEmpty ? "Say “navigate to”, then a place." : model.heard)
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(3)
        }
      } else {
        connectCard
      }
    }
  }

  private var listeningRing: some View {
    ZStack {
      Circle()
        .fill(Theme.accent.opacity(0.10))
        .frame(width: 210, height: 210)
        .scaleEffect(pulse ? 1.06 : 0.96)
        .opacity(pulse ? 0.4 : 0.9)
      Circle()
        .stroke(Theme.accent.opacity(0.35), lineWidth: 1.5)
        .frame(width: 170, height: 170)
      Image(systemName: "mic.fill")
        .font(.system(size: 44, weight: .medium))
        .foregroundStyle(Theme.accent)
    }
    .onAppear {
      withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
    .onDisappear { pulse = false }
  }

  private var connectCard: some View {
    VStack(spacing: 20) {
      VStack(spacing: 12) {
        Image(systemName: "eyeglasses")
          .font(.system(size: 40, weight: .light))
          .foregroundStyle(Theme.accent)
        Text(title)
          .font(.system(size: 28, weight: .semibold, design: .rounded))
          .foregroundStyle(Theme.primary)
          .multilineTextAlignment(.center)
        Text(detail)
          .font(.system(size: 16, weight: .regular, design: .rounded))
          .foregroundStyle(Theme.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 12) {
        Button(primaryLabel) {
          model.connectGlasses()
        }
        .buttonStyle(PrimaryButtonStyle(filled: model.linkState == .notRegistered))
      }
    }
    .padding(28)
    .background(
      RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        .fill(Theme.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        .stroke(Theme.stroke, lineWidth: 1)
    )
  }

  private var title: String {
    switch model.linkState {
    case .notRegistered: return "Connect your glasses"
    case .waitingForGlasses: return "Waiting for your glasses"
    case .connecting: return "Connecting"
    case .needsMicrophonePermission: return "Allow the microphone"
    case .failed: return "Something went wrong"
    case .ready, .starting: return "Getting ready"
    }
  }

  private var detail: String {
    switch model.linkState {
    case .notRegistered:
      return "Tap the button. Meta AI will open and ask you to approve MetaNav."
    case .waitingForGlasses:
      return "Put your glasses on and make sure they are connected in the Meta AI app."
    case .connecting:
      return "Hang on a moment."
    case .needsMicrophonePermission(let reason):
      return "Meta AI needs to allow the microphone. \(reason)"
    case .failed(let message):
      return message
    case .ready, .starting:
      return "One moment."
    }
  }

  /// One button, worded for where things are. It always does the next useful thing:
  /// approve the app the first time, and simply try again after that.
  private var primaryLabel: String {
    switch model.linkState {
    case .notRegistered: return "Connect your glasses"
    case .needsMicrophonePermission: return "Try again"
    case .waitingForGlasses, .connecting, .failed, .starting: return "Try again"
    case .ready: return "Connect your glasses"
    }
  }
}

// MARK: - Choosing

private struct ChoosingView: View {
  @ObservedObject var model: NavigationController

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text("Which one?")
          .font(.system(size: 30, weight: .semibold, design: .rounded))
          .foregroundStyle(Theme.primary)
        Text("Say “first”, “second”, or “third”.")
          .font(.system(size: 15, weight: .regular, design: .rounded))
          .foregroundStyle(Theme.secondary)
      }

      VStack(spacing: 12) {
        ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
          Button {
            model.chooseFromScreen(candidate)
          } label: {
            HStack(spacing: 16) {
              Text(ordinal(index))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.background)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent))

              VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                  .font(.system(size: 17, weight: .semibold, design: .rounded))
                  .foregroundStyle(Theme.primary)
                  .lineLimit(1)
                if !candidate.detail.isEmpty {
                  Text(candidate.detail)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                }
              }
              Spacer(minLength: 0)
            }
            .padding(16)
            .background(
              RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1)
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private func ordinal(_ index: Int) -> String {
    switch index {
    case 0: return "1"
    case 1: return "2"
    default: return "3"
    }
  }
}

// MARK: - Navigating

private struct NavigatingView: View {
  @ObservedObject var model: NavigationController

  var body: some View {
    VStack(spacing: 22) {
      VStack(spacing: 10) {
        Text(model.distanceToTurn)
          .font(.system(size: 15, weight: .semibold, design: .rounded))
          .foregroundStyle(Theme.accent)
          .tracking(1.2)

        Text(model.nextInstruction)
          .font(.system(size: 34, weight: .semibold, design: .rounded))
          .foregroundStyle(Theme.primary)
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.6)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(26)
      .frame(maxWidth: .infinity)
      .background(
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
          .fill(Theme.surface)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
          .stroke(Theme.stroke, lineWidth: 1)
      )

      HStack(spacing: 10) {
        InfoTile(label: "Left", value: model.remainingText)
        InfoTile(label: "Arrive", value: model.arrivalText)
      }

      Text(model.destinationName)
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.secondary)

      VStack(spacing: 10) {
        Button("Stop navigation") {
          model.stopNavigation()
        }
        .buttonStyle(PrimaryButtonStyle(filled: false))

        Button("Open in Maps") {
          model.openInMaps()
        }
        .buttonStyle(PrimaryButtonStyle(filled: false))
      }
    }
  }
}

private struct InfoTile: View {
  var label: String
  var value: String

  var body: some View {
    VStack(spacing: 4) {
      Text(label)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.secondary)
        .textCase(.uppercase)
        .tracking(1)
      Text(value.isEmpty ? "—" : value)
        .font(.system(size: 18, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.primary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Theme.surface)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Theme.stroke, lineWidth: 1)
    )
  }
}

// MARK: - Working and errors

private struct WorkingView: View {
  var title: String
  var subtitle: String
  @State private var spin = false

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "location.north.line")
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(Theme.accent)
        .rotationEffect(.degrees(spin ? 360 : 0))
        .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: spin)

      Text(title)
        .font(.system(size: 24, weight: .semibold, design: .rounded))
        .foregroundStyle(Theme.primary)

      if !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 15, weight: .regular, design: .rounded))
          .foregroundStyle(Theme.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .onAppear { spin = true }
  }
}

private struct ErrorView: View {
  var message: String
  @ObservedObject var model: NavigationController

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(Theme.warning)

      Text(message)
        .font(.system(size: 18, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.primary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      // "Try again" would only fail the same way, so when the problem is a setting
      // the button takes the wearer straight to where it can be fixed.
      if model.needsLocationSettings {
        Button("Open Settings") {
          model.openSettings()
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.top, 6)
      } else {
        Button("OK") {
          model.dismissError()
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.top, 6)
      }
    }
    .padding(28)
  }
}
