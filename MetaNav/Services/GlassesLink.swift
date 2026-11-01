import Foundation
import MWDATCore
import MWDATSpeech

/// The connection to the glasses, and the only place that talks to Meta's SDK.
///
/// It does four things, in this order: wait until the app is registered with the Meta AI
/// app, open a session on the glasses that are connected, ask for the microphone, and
/// then turn the glasses into a microphone that hands back text.
@MainActor
final class GlassesLink {
  enum State: Equatable {
    case starting
    case notRegistered
    case waitingForGlasses
    case connecting
    /// The glasses microphone is refused, with the reason the SDK gave for it.
    case needsMicrophonePermission(String)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
  }

  /// Called with each finished sentence the glasses heard.
  var onTranscript: ((String) -> Void)?
  var onStateChange: ((State) -> Void)?
  /// Called the first moment the glasses are usable, so the app can start listening.
  var onReady: (() -> Void)?

  private(set) var state: State = .starting {
    didSet {
      guard state != oldValue else { return }
      onStateChange?(state)
      if state == .ready { onReady?() }
    }
  }

  private(set) var deviceIdentifier: DeviceIdentifier?

  private var session: DeviceSession?
  private var speech: Speech?
  private let tokens = ListenerTokenBag()

  private var wantsListening = false
  private var isPaused = false
  private var hasAttachedSpeech = false
  /// Whether the recogniser has actually come up this run. `stopped` is both the state it
  /// is born in and the state it dies in, and only the second one is worth restarting.
  private var speechHasStarted = false
  /// Guards against two callers attaching the microphone at the same time, which the
  /// glasses would reject as "already active".
  private var isAttachingSpeech = false
  /// Whether the app is waiting for the glasses to finish linking before opening a session.
  private var isWaitingForLink = false
  private var restartTask: Task<Void, Never>?
  /// Keeps asking the SDK to reach the glasses while the link is still down.
  private var knockTask: Task<Void, Never>?

  private var wearables: any WearablesInterface { Wearables.shared }

  // MARK: - Lifecycle

  /// Called once, at launch.
  func begin() {
    let registered = wearables.registrationState.isRegistered
    state = registered ? .waitingForGlasses : .notRegistered
    DebugLog.write("begin: registered=\(registered), devices=\(wearables.devices.count)")

    Task { [weak self] in
      guard let self else { return }
      for await registration in self.wearables.registrationStateStream() {
        self.handleRegistration(registration)
      }
    }

    Task { [weak self] in
      guard let self else { return }
      for await identifiers in self.wearables.devicesStream() {
        self.handleDevices(identifiers)
      }
    }

    // A stream may only report changes. If the app was already approved and the glasses
    // were already connected, this is what actually opens the session.
    if registered, let first = wearables.devices.first {
      connect(to: first)
    }
  }

  /// Opens the Meta AI app so the wearer can approve this app. When that has already
  /// happened, this is the same as "try again" — approving twice would only be an error.
  func register() {
    if wearables.registrationState.isRegistered {
      retry()
      return
    }

    Task { [weak self] in
      guard let self else { return }
      do {
        try await self.wearables.startRegistration()
      } catch {
        self.state = .failed(error.localizedDescription)
      }
    }
  }

  /// Tries again after a failure, without leaving the app.
  func retry() {
    // The session may still be alive with only the microphone missing (the wearer had
    // to grant it in Meta AI). Reusing it is quicker than starting over.
    if session != nil {
      if let speech, hasAttachedSpeech {
        if speech.state == .started {
          state = .ready
        } else {
          speechHasStarted = false
          scheduleRestart(speech)
          state = .connecting
        }
      } else {
        Task { [weak self] in
          await self?.attachSpeechIfPossible()
        }
      }
      return
    }

    if let identifier = deviceIdentifier {
      connect(to: identifier)
    } else if let first = wearables.devices.first {
      connect(to: first)
    } else {
      state = .waitingForGlasses
    }
  }

  // MARK: - Registration and devices

  private func handleRegistration(_ registration: RegistrationState) {
    DebugLog.write("registration: \(registration.description)")
    if registration.isRegistered {
      if let identifier = deviceIdentifier {
        connect(to: identifier)
      } else if let first = wearables.devices.first {
        connect(to: first)
      } else {
        state = .waitingForGlasses
      }
    } else if registration == .registering {
      // The wearer is answering the approval prompt in Meta AI. Tearing the session
      // down here would drop them back to the connect screen while they decide.
      state = .connecting
    } else {
      tearDown()
      state = .notRegistered
    }
  }

  private func handleDevices(_ identifiers: [DeviceIdentifier]) {
    DebugLog.write("devices: \(identifiers.count)")
    guard wearables.registrationState.isRegistered else { return }

    // Already connected, or already waiting for this pair: nothing to do unless the
    // glasses went away.
    if let current = deviceIdentifier, identifiers.contains(current),
      session != nil || isWaitingForLink
    {
      return
    }

    guard let first = identifiers.first else {
      if session == nil { state = .waitingForGlasses }
      return
    }

    connect(to: first)
  }

  // MARK: - Session

  private func connect(to identifier: DeviceIdentifier) {
    // A session that is still alive is already the connection we want.
    if deviceIdentifier == identifier, let session, session.state != .stopped { return }
    // The same glasses are already being waited on; the link listener opens the session.
    if deviceIdentifier == identifier, isWaitingForLink { return }

    tearDown()

    deviceIdentifier = identifier
    DebugLog.write("connect: \(identifier)")

    guard let device = wearables.deviceForIdentifier(identifier) else {
      state = .waitingForGlasses
      return
    }

    DebugLog.write(
      "device: link=\(Self.name(device.linkState)) don=\(Self.name(device.donState)) "
        + "battery=\(device.batteryLevel.map(String.init) ?? "-") "
        + "compat=\(String(describing: device.compatibility()))"
    )

    // Old glasses software cannot run this app. Meta AI is where the update is installed,
    // so that is opened for the wearer instead of leaving them with an error to read.
    if device.compatibility() == .deviceUpdateRequired {
      state = .failed("Your glasses need a software update. Meta AI will open to install it.")
      Task { [weak self] in
        try? await self?.wearables.openFirmwareUpdate()
      }
      return
    }

    // The SDK knows a pair as soon as it is remembered, long before the glasses answer.
    // A session asked for in that gap is refused as "no eligible device", so the link is
    // waited on first — and watched afterwards, since glasses come and go all day.
    device.addLinkStateListener { [weak self] link in
      Task { @MainActor in
        self?.handle(link: link)
      }
    }.store(in: tokens)

    if device.linkState == .connected {
      openSession(for: identifier)
    } else {
      isWaitingForLink = true
      state = .waitingForGlasses
      startKnocking(for: identifier)
    }
  }

  private func handle(link: LinkState) {
    DebugLog.write("link: \(Self.name(link))")
    guard session == nil else { return }

    switch link {
    case .connected:
      if let identifier = deviceIdentifier { openSession(for: identifier) }
    case .disconnected, .connecting:
      isWaitingForLink = true
      if state == .starting || state == .connecting { state = .waitingForGlasses }
    }
  }

  private func openSession(for identifier: DeviceIdentifier, attempt: Int = 1) {
    isWaitingForLink = false
    state = .connecting
    DebugLog.write("opening session (try \(attempt))")
    knockTask?.cancel()
    knockTask = nil

    let session: DeviceSession
    do {
      session = try wearables.createSession(
        deviceSelector: SpecificDeviceSelector(device: identifier)
      )
    } catch {
      DebugLog.write("create session failed: \(String(describing: error))")
      retrySession(for: identifier, after: error, attempt: attempt)
      return
    }

    self.session = session

    Task { [weak self] in
      guard let self else { return }
      for await sessionState in session.stateStream() {
        self.handleSessionState(sessionState, for: session)
      }
    }

    Task { [weak self] in
      guard let self else { return }
      for await error in session.errorStream() {
        guard session === self.session else { return }
        // Most session failures end with the state stream reporting `stopped`. The one
        // that is somebody's to fix gets said plainly instead, with Meta AI opened at the
        // place the fix lives.
        if error == .datAppOnTheGlassesUpdateRequired {
          self.state = .failed("Meta AI on your glasses needs an update. Meta AI will open.")
          try? await self.wearables.openDATGlassesAppUpdate()
        }
      }
    }

    do {
      try session.start()
      DebugLog.write("session start requested, state=\(String(describing: session.state))")
    } catch {
      DebugLog.write("session start failed: \(String(describing: error))")
      self.session = nil
      retrySession(for: identifier, after: error, attempt: attempt)
      return
    }

    // `stateStream()` may only report changes, so a session that started immediately
    // could otherwise never reach `handleSessionState`.
    if session.state == .started {
      Task { [weak self] in
        await self?.attachSpeechIfPossible()
      }
    }
  }

  /// Keeps asking the SDK to reach the glasses while the link is still down, so a missed
  /// 2-second connect window can never be missed entirely. The ask is harmless when the
  /// glasses are unreachable: it simply reports them as off.
  private func startKnocking(for identifier: DeviceIdentifier) {
    knockTask?.cancel()
    knockTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        guard let self, self.deviceIdentifier == identifier, self.session == nil, self.isWaitingForLink
        else { return }
        if self.wearables.deviceForIdentifier(identifier)?.linkState == .connected {
          self.openSession(for: identifier)
          return
        }
        _ = try? await self.wearables.checkPermissionStatus(.microphone)
      }
    }
  }

  /// The glasses can be in range and still refuse for a moment while their own copy of
  /// the toolkit app wakes up, so a few quiet retries come before the wearer is told.
  private func retrySession(for identifier: DeviceIdentifier, after error: DeviceSessionError, attempt: Int) {
    if error == .noEligibleDevice, attempt < 6 {
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let self, self.deviceIdentifier == identifier, self.session == nil else { return }
        self.openSession(for: identifier, attempt: attempt + 1)
      }
      return
    }

    if error == .noEligibleDevice {
      state = .failed(
        "MetaNav cannot reach your glasses yet. In Meta AI: Settings, App info, Developer mode, "
          + "then Install next to your glasses. Put them on first."
      )
      return
    }

    if error == .datAppOnTheGlassesUpdateRequired {
      state = .failed("Your glasses need the toolkit app. Meta AI will open to install it.")
      Task { [weak self] in
        try? await self?.wearables.openDATGlassesAppUpdate()
      }
      return
    }

    state = .failed(error.localizedDescription)
  }

  private func handleSessionState(_ sessionState: DeviceSessionState, for session: DeviceSession) {
    // A session that has already been replaced or torn down must not speak for the app.
    guard session === self.session else { return }
    DebugLog.write("session: \(String(describing: sessionState))")

    if sessionState == .started {
      Task { [weak self] in
        await self?.attachSpeechIfPossible()
      }
    } else if sessionState == .stopped {
      hasAttachedSpeech = false
      speechHasStarted = false
      speech = nil
      wantsListening = false
      isPaused = false
      restartTask?.cancel()
      restartTask = nil
      // A stopped session is finished for good; a new one has to be opened, so this one
      // is let go and "try again" is allowed to build a fresh link.
      self.session = nil
      if state != .notRegistered, deviceIdentifier != nil {
        state = .failed("The glasses stopped the connection.")
      }
    }
  }

  // MARK: - Microphone and speech

  private func attachSpeechIfPossible() async {
    guard let session, !hasAttachedSpeech, !isAttachingSpeech else { return }
    isAttachingSpeech = true
    defer { isAttachingSpeech = false }

    DebugLog.write("microphone: checking")

    // The glasses microphone is a permission the wearer grants inside the Meta AI app,
    // so this may bounce them over there for a moment.
    var status: PermissionStatus
    do {
      status = try await wearables.checkPermissionStatus(.microphone)
      DebugLog.write("microphone check: \(Self.readable(status))")
      if status != .granted {
        status = try await wearables.requestPermission(.microphone)
        DebugLog.write("microphone request: \(Self.readable(status))")
      }
    } catch {
      DebugLog.write("microphone request failed: \(error.description)")
      state = .needsMicrophonePermission(
        "Meta AI did not open the microphone question (\(error.description))."
      )
      return
    }
    guard status == .granted else {
      DebugLog.write("microphone refused")
      state = .needsMicrophonePermission("Meta AI said no to the microphone.")
      return
    }

    // The wearer may have taken a while in Meta AI; if the session was replaced or torn
    // down meanwhile, this one is no longer ours to use.
    guard self.session === session, !hasAttachedSpeech else { return }

    // A session says "started" a moment before the glasses are actually reachable, and a
    // capability asked for in that window fails without retrying itself. So the ask is
    // tried a few times, a second apart, before it is called a failure.
    var attached: Speech?
    var attempts = 0
    while true {
      attempts += 1
      do {
        attached = try session.addSpeech()
        break
      } catch {
        DebugLog.write("speech attach failed (\(attempts)): \(error.localizedDescription)")
        if attempts >= 5 {
          state = .failed("The glasses would not turn on the microphone.")
          return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard self.session === session, !hasAttachedSpeech else { return }
      }
    }

    guard let speech = attached else {
      // `nil` means this pair has no on-device speech at all. That is hardware, not a
      // fault that a retry would fix.
      DebugLog.write("speech unavailable")
      state = .failed("These glasses cannot do voice input.")
      return
    }

    DebugLog.write("speech attached")
    self.speech = speech
    hasAttachedSpeech = true

    speech.transcriptionPublisher.listen { [weak self] result in
      guard result.isFinal else { return }
      let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      Task { @MainActor in
        self?.onTranscript?(text)
      }
    }.store(in: tokens)

    speech.statePublisher.listen { [weak self] speechState in
      Task { @MainActor in
        self?.handleSpeechState(speechState)
      }
    }.store(in: tokens)

    speech.errorPublisher.listen { [weak self] error in
      Task { @MainActor in
        self?.handleSpeechError(error)
      }
    }.store(in: tokens)

    wantsListening = true
    speech.start()
    state = .ready
  }

  private func handleSpeechState(_ speechState: SpeechState) {
    if speechState == .started {
      speechHasStarted = true
      if session != nil { state = .ready }
      return
    }

    // The glasses stop listening on their own after a while, or after a timeout. If the
    // app still wants to listen, start it again — otherwise the wearer talks to nothing.
    // Only a recogniser that was actually up is restarted; `stopped` is also the state
    // it is born in, and chasing that one would fight its first start.
    guard speechState == .stopped, speechHasStarted, wantsListening, !isPaused, let speech
    else { return }
    speechHasStarted = false
    scheduleRestart(speech)
  }

  private func handleSpeechError(_ error: SpeechError) {
    speechHasStarted = false

    // `unavailable` is a fact about the hardware, not a link that will come back. Every
    // other error is a moment — a disconnect, a start that failed — and is retried.
    if error == .unavailable {
      state = .failed("These glasses cannot do voice input.")
      return
    }

    guard wantsListening, !isPaused, let speech else { return }
    // Do not claim to be listening while the recogniser is down.
    if state == .ready { state = .connecting }
    scheduleRestart(speech)
  }

  private func scheduleRestart(_ speech: Speech) {
    restartTask?.cancel()
    restartTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 700_000_000)
      guard !Task.isCancelled else { return }
      guard let self, self.speech === speech else { return }
      self.startSpeechIfStopped()
    }
  }

  /// Starting a recogniser that is already starting, stopping or up is an error, so this
  /// only ever starts one that is fully stopped. Every place that wants the microphone
  /// goes through here, which makes a stop that lands a moment late harmless.
  private func startSpeechIfStopped() {
    guard wantsListening, !isPaused, let speech, speech.state == .stopped else { return }
    speech.start()
  }

  // MARK: - Listening control

  /// Stops the glasses microphone while the phone is talking, so the app never hears
  /// itself and mistakes it for the wearer.
  func pauseListening() {
    guard wantsListening else { return }
    isPaused = true
    restartTask?.cancel()
    speech?.stop()
  }

  func resumeListening() {
    isPaused = false
    // If the glasses are still finishing the stop, the state listener picks it up and
    // starts them again. Asking now would be an error the SDK reports back to us.
    startSpeechIfStopped()
  }

  // MARK: - Teardown

  func tearDown() {
    wantsListening = false
    isPaused = false
    isWaitingForLink = false
    knockTask?.cancel()
    knockTask = nil
    restartTask?.cancel()
    restartTask = nil
    speech?.stop()
    speech = nil
    hasAttachedSpeech = false
    speechHasStarted = false
    tokens.clear()
    session?.stop()
    session = nil
    deviceIdentifier = nil
  }
}

private extension GlassesLink {
  static func readable(_ status: PermissionStatus) -> String {
    switch status {
    case .granted: return "granted"
    case .denied: return "denied"
    @unknown default: return "unknown"
    }
  }

  static func name(_ link: LinkState) -> String {
    switch link {
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    }
  }

  static func name(_ don: DonState) -> String {
    switch don {
    case .unknown: return "unknown"
    case .doffed: return "doffed"
    case .donned: return "donned"
    }
  }
}

private extension RegistrationState {
  var isRegistered: Bool {
    if case .registered = self { return true }
    return false
  }
}
