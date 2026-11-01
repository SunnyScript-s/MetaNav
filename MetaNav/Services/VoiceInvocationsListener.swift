import Foundation
import MWDATCore

/// Answers "Hey Meta, start MetaNav".
///
/// This is the part that makes the whole thing hands-free: the wearer says the phrase,
/// Meta AI opens this app, and the app starts listening for the destination. If the phrase
/// is not set up in Meta's developer site yet, everything still works — the app just has
/// to be opened by hand.
///
/// Two details from Meta's own sample matter here:
///
/// - Meta AI holds the invocation open until the app answers through the response handle,
///   so the answer goes back before anything else happens.
/// - A dropped channel arrives on the error publisher rather than by ending the stream. If
///   that drop were ignored, "Hey Meta, start MetaNav" would stay broken for the rest of
///   the run, so the channel is reopened instead.
@MainActor
final class VoiceInvocationsListener {
  /// Called when Meta AI opens the app through a voice invocation. The optional text is
  /// whatever Meta AI attached to the launch — for a navigation request that would be the
  /// place — and lets the app start straight into a trip instead of waiting for the wearer
  /// to say the destination out loud.
  var onLaunch: ((String?) -> Void)?

  private var stream: VoiceInvocationsStream?
  private var invocationToken: (any AnyListenerToken)?
  private var errorToken: (any AnyListenerToken)?
  private var listeningOn: DeviceIdentifier?
  private var reopenTask: Task<Void, Never>?

  /// How long to wait before trying the channel again. The wearer is usually waiting on
  /// the launch, so this stays short; it is not a busy loop because each attempt is one
  /// SDK call.
  private static let reopenDelayNanos: UInt64 = 2_000_000_000

  /// Safe to call repeatedly; it only reopens the channel when the device changes or the
  /// channel has gone down.
  func listen(on identifier: DeviceIdentifier) {
    if listeningOn == identifier, stream != nil { return }

    reopenTask?.cancel()
    reopenTask = nil
    stop()
    listeningOn = identifier
    open()
  }

  func stop() {
    reopenTask?.cancel()
    reopenTask = nil
    stream?.stop()
    stream = nil
    invocationToken = nil
    errorToken = nil
    listeningOn = nil
  }

  // MARK: - Channel

  private func open() {
    guard let identifier = listeningOn else { return }

    do {
      let stream = try VoiceInvocationsStream(wearables: Wearables.shared)

      // Listeners first, so an invocation that lands during start is not missed.
      invocationToken = stream.invocationsPublisher.listen { [weak self] invocation in
        guard let launch = invocation as? LaunchApp else { return }
        Task { @MainActor in
          // Meta AI holds the request open until the app answers. Answering is the
          // difference between "opening" and "opened".
          _ = await launch.responseHandle.sendSuccess(actionOutput: nil)
          self?.onLaunch?(nil)
        }
      }

      errorToken = stream.errorPublisher.listen { [weak self] _ in
        Task { @MainActor in
          self?.channelDropped()
        }
      }

      try stream.start(deviceIdentifier: identifier)
      self.stream = stream
    } catch {
      // No connected device yet, or the link is still coming up. Try again shortly.
      clearChannel()
      scheduleReopen()
    }
  }

  private func channelDropped() {
    guard listeningOn != nil else { return }
    clearChannel()
    scheduleReopen()
  }

  private func clearChannel() {
    stream?.stop()
    stream = nil
    invocationToken = nil
    errorToken = nil
  }

  private func scheduleReopen() {
    guard let identifier = listeningOn else { return }

    reopenTask?.cancel()
    reopenTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.reopenDelayNanos)
      guard !Task.isCancelled, let self, self.listeningOn == identifier else { return }
      self.open()
    }
  }
}
