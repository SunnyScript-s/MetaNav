import CoreBluetooth
import Foundation
import MWDATCore
import SwiftUI

@main
struct MetaNavApp: App {
  @StateObject private var model = NavigationController()

  init() {
    // Must happen before anything touches the glasses SDK.
    DebugLog.write("bluetooth: \(Self.bluetoothName(CBManager.authorization))")
    do {
      try Wearables.configure()
      DebugLog.write("configured")
    } catch {
      DebugLog.write("configure failed: \(error)")
      NSLog("MetaNav: the glasses SDK would not start: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .onOpenURL { url in
          handleCallback(url)
        }
        .task {
          model.start()
          #if DEBUG
          model.handleDebugArguments()
          #endif
        }
    }
  }

  /// Meta AI sends the wearer back here after they approve the app or grant the
  /// microphone. The URL has to be handed to the SDK unchanged: it decides whether the
  /// link is one of its own and returns `false` for anything else. Filtering on a query
  /// parameter here would drop callbacks that do not happen to carry it.
  private func handleCallback(_ url: URL) {
    // A `metanav://navigate?q=…` link is ours, not Meta's.
    if model.handle(url: url) { return }

    DebugLog.write("callback: \(url.scheme ?? "-")")
    Task {
      do {
        let handled = try await Wearables.shared.handleUrl(url)
        DebugLog.write("callback handled: \(handled)")
      } catch {
        DebugLog.write("callback failed: \(String(describing: error))")
      }
    }
  }

  private static func bluetoothName(_ authorization: CBManagerAuthorization) -> String {
    switch authorization {
    case .allowedAlways: return "allowed"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not asked"
    @unknown default: return "unknown"
    }
  }
}
