import AVFoundation
import Combine
import CoreLocation
import Foundation
import MapKit
import UIKit

/// The app's brain: it listens, searches, plans, and talks.
///
/// Everything the screen shows comes from here, and every spoken line comes from here, so
/// the whole behaviour can be followed in one file.
@MainActor
final class NavigationController: ObservableObject {
  enum Phase: Equatable {
    case idle
    case searching
    case choosing
    case navigating
    case failed(String)

    var isBusy: Bool { self == .searching }
  }

  // What the screen shows.
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var status: String = "Starting up"
  @Published private(set) var heard: String = ""
  @Published private(set) var candidates: [PlaceCandidate] = []
  @Published private(set) var nextInstruction: String = ""
  @Published private(set) var distanceToTurn: String = ""
  @Published private(set) var remainingText: String = ""
  @Published private(set) var arrivalText: String = ""
  @Published private(set) var destinationName: String = ""
  @Published private(set) var isListening: Bool = false
  @Published private(set) var isSpeaking: Bool = false
  @Published private(set) var linkState: GlassesLink.State = .starting
  @Published private(set) var locationDenied: Bool = false

  // The machinery.
  private let link = GlassesLink()
  private let speaker = Speaker()
  private let location = LocationTracker()
  private let searcher = PlaceSearcher()
  private let planner = RoutePlanner()
  private let voiceInvocations = VoiceInvocationsListener()

  // Trip state.
  private var guide: TurnByTurn?
  private var route: PlannedRoute?
  private var progress: RouteProgress?
  /// Metres per second, taken from the planned route, so the arrival time can be
  /// re-estimated as the trip goes on.
  private var averageSpeed: Double = 0
  private var destination: PlaceCandidate?
  private var mode: TravelMode = .driving
  private var offRouteFixes = 0
  private var lastReroute = Date.distantPast
  private var isReplanning = false

  private var hasStarted = false
  /// Transcripts that arrive while (or just after) the app is talking are its own words
  /// coming back through the glasses microphone, not the wearer.
  private var ignoreTranscriptsUntil = Date.distantPast

  // MARK: - Start up

  func start() {
    guard !hasStarted else { return }
    hasStarted = true

    speaker.configureAudioSession()
    location.requestPermission()
    // Low-power updates from the start: they are what keeps the app alive between trips,
    // so the glasses can still be heard with the phone in a pocket.
    location.startStayingAlive()
    locationDenied = {
      let status = location.authorizationStatus
      return status == .denied || status == .restricted
    }()

    location.onAuthorizationChange = { [weak self] status in
      guard let self else { return }
      self.locationDenied = status == .denied || status == .restricted

      // The wearer just came back from Settings. Clear the location error and let them
      // carry on, instead of leaving a dead end on the screen.
      if !self.locationDenied, case .failed = self.phase {
        self.phase = .idle
        DebugLog.write("phase: idle")
        self.status = self.linkState.isReady ? "Listening" : Self.describe(self.linkState)
        self.isListening = self.linkState.isReady
        self.say("Ready. Say navigate to, then a place.")
      }
    }

    link.onStateChange = { [weak self] state in
      guard let self else { return }
      self.linkState = state
      self.isListening = state.isReady
      self.status = Self.describe(state)

      // "Hey Meta, start MetaNav" is a Wearables-level stream: it needs no device
      // session, so open it as soon as a device is known, not only when ready.
      if let identifier = self.link.deviceIdentifier {
        self.voiceInvocations.listen(on: identifier)
      }

      if state == .ready, self.phase == .idle {
        self.say("Ready. Say navigate to, then a place.")
      }
    }

    link.onReady = { [weak self] in
      guard let self else { return }
      if let identifier = self.link.deviceIdentifier {
        self.voiceInvocations.listen(on: identifier)
      }
    }

    link.onTranscript = { [weak self] text in
      self?.handle(transcript: text)
    }

    location.onUpdate = { [weak self] point in
      self?.handle(position: point)
    }

    voiceInvocations.onLaunch = { [weak self] destination in
      guard let self else { return }

      // A launch that hands us a place ("Hey Meta, navigate to X") skips the extra step of
      // telling the wearer to say the destination out loud. Anything else just starts the
      // listening loop.
      if let destination, !destination.isEmpty, let parsed = PhraseParser.destination(from: destination) {
        stopNavigation()
        candidates = []
        heard = destination
        beginSearch(for: parsed)
        return
      }

      if self.phase == .navigating {
        self.repeatInstruction()
      } else if self.linkState.isReady, !self.isSpeaking {
        // The invocation only says "start MetaNav"; the place comes next.
        self.say("Say navigate to, then a place.")
      }
    }

    // `begin()` reports the first state through `onStateChange`, which sets `status`. Do
    // not write a status after it, or it would overwrite the real one and leave the pill
    // saying "Starting up" until something else happened.
    link.begin()
  }

  /// The screen's one big button: opens Meta AI to approve the app.
  func connectGlasses() {
    link.register()
  }

  func retry() {
    link.retry()
  }

  /// Tapping the big button while idle is a gentle prompt, not a microphone start —
  /// the glasses are already listening whenever they are ready.
  func promptForDestination() {
    if linkState == .ready {
      say("Say navigate to, then a place.")
    } else {
      status = Self.describe(linkState)
    }
  }

  // MARK: - Hearing

  /// A second way in, for a phone Shortcut or for testing without glasses:
  /// `metanav://navigate?q=Starbucks`, with an optional `&mode=walking`.
  ///
  /// Returns `false` for any other link, so the glasses SDK can still see its own
  /// callbacks.
  func handle(url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "metanav",
      components.host?.lowercased() == "navigate"
    else { return false }

    let items = components.queryItems ?? []
    guard let spoken = items.first(where: { $0.name == "q" })?.value else { return false }
    let query = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return false }

    let mode =
      items.first(where: { $0.name == "mode" })?.value
      .flatMap { TravelMode(rawValue: $0.lowercased()) } ?? .driving

    // The same path a spoken request takes, so a link cannot skip a step.
    stopNavigation()
    candidates = []
    heard = query
    beginSearch(for: ParsedDestination(query: query, mode: mode))
    return true
  }

  #if DEBUG
  /// Lets a simulator build be driven from the command line, so the search, routing and
  /// speaking paths can be exercised without glasses:
  ///
  ///     xcrun simctl launch <udid> com.santiagoharbison.metanav -navigate "Starbucks"
  ///
  /// Never compiled into a release build.
  func handleDebugArguments() {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "-navigate"), index + 1 < arguments.count
    else { return }

    let query = arguments[index + 1]
    var mode = TravelMode.driving
    if let modeIndex = arguments.firstIndex(of: "-mode"), modeIndex + 1 < arguments.count,
      let parsed = TravelMode(rawValue: arguments[modeIndex + 1].lowercased())
    {
      mode = parsed
    }

    heard = query
    beginSearch(for: ParsedDestination(query: query, mode: mode))

    // Picking one of the options a moment later, so the whole trip can be seen without
    // tapping anything.
    if let choiceIndex = arguments.firstIndex(of: "-choose"),
      choiceIndex + 1 < arguments.count
    {
      let word = arguments[choiceIndex + 1]
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 7_000_000_000)
        self?.handleChoice(word)
      }
    }
  }
  #endif

  private func handle(transcript: String) {
    guard !isSpeaking, Date() >= ignoreTranscriptsUntil else { return }

    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    heard = text

    switch phase {
    case .choosing:
      handleChoice(text)
    case .navigating:
      handleWhileNavigating(text)
    case .searching:
      break
    case .idle, .failed:
      handleNewRequest(text)
    }
  }

  private func handleNewRequest(_ text: String) {
    if let parsed = PhraseParser.destination(from: text) {
      beginSearch(for: parsed)
      return
    }

    if PhraseParser.isStopCommand(text) {
      say("Nothing is running.")
      return
    }

    say("Say navigate to, then a place.")
  }

  private func handleWhileNavigating(_ text: String) {
    if PhraseParser.isStopCommand(text) {
      stopNavigation()
      say("Navigation stopped.")
      return
    }
    if PhraseParser.isRepeatCommand(text) {
      repeatInstruction()
      return
    }
    // A new place mid-trip is a change of plan, not chatter.
    if let parsed = PhraseParser.destination(from: text) {
      stopNavigation()
      beginSearch(for: parsed)
    }
  }

  private func handleChoice(_ text: String) {
    if let index = ChoiceParser.index(from: text, optionCount: candidates.count) {
      choose(index)
      return
    }

    // "Actually, navigate to the other one" should work without saying cancel first.
    if let parsed = PhraseParser.destination(from: text) {
      candidates = []
      beginSearch(for: parsed)
      return
    }

    if PhraseParser.isCancelCommand(text) {
      candidates = []
      phase = .idle
      DebugLog.write("phase: idle")
      location.startStayingAlive()
      say("Okay. Say navigate to, then a place.")
      return
    }

    say("Say first, second, or third.")
  }

  // MARK: - Searching

  private func beginSearch(for parsed: ParsedDestination) {
    // Only a settled answer is worth refusing for: right after launch the status can read
    // "denied" for a moment before locationd has answered.
    if location.hasSettledAuthorization, !location.hasPermission {
      locationDenied = true
      fail("I need your location. Open Settings, then allow location for MetaNav.")
      return
    }

    mode = parsed.mode
    phase = .searching
    DebugLog.write("phase: searching")
    status = "Looking for \(parsed.query.capitalized)"

    Task { [weak self] in
      guard let self else { return }
      // A cached fix is used when it is fresh; otherwise this waits briefly for one.
      let origin = await self.location.currentPoint(timeout: 3)

      do {
        let results = try await self.searcher.search(parsed.query, near: origin)
        guard !results.isEmpty else {
          self.fail("I couldn't find \(parsed.query).")
          return
        }

        if results.count == 1, let only = results.first {
          // No "okay" line here: the route announcement follows in a moment and would
          // cut it off mid-sentence.
          self.planTrip(to: only)
        } else {
          self.candidates = results
          self.phase = .choosing
          DebugLog.write("phase: choosing")
          self.status = "Which one?"
          self.say("I found \(results.count). \(Self.readOut(results)) Which one?")
        }
      } catch {
        self.fail(error.localizedDescription)
      }
    }
  }

  private func choose(_ index: Int) {
    guard index >= 0, index < candidates.count else { return }
    let picked = candidates[index]
    candidates = []
    planTrip(to: picked)
  }

  /// For the on-screen list: tapping an option does the same thing as saying it.
  func chooseFromScreen(_ candidate: PlaceCandidate) {
    guard let index = candidates.firstIndex(of: candidate) else { return }
    choose(index)
  }

  // MARK: - Planning

  private func planTrip(to candidate: PlaceCandidate) {
    phase = .searching
    DebugLog.write("phase: searching")
    status = "Getting directions to \(candidate.name)"

    // The first time, the phone is probably showing the permission prompt, so give the
    // wearer longer to answer it.
    let timeout: TimeInterval = location.hasSettledAuthorization ? 6 : 12

    Task { [weak self] in
      guard let self else { return }

      guard let origin = await self.location.currentPoint(timeout: timeout) else {
        // Now the status has had time to settle, so a "no" here is a real one.
        let authorization = self.location.authorizationStatus
        let denied = authorization == .denied || authorization == .restricted
        self.locationDenied = denied
        self.fail(
          denied
            ? "I need your location. Open Settings, then allow location for MetaNav."
            : "I need your location to guide you."
        )
        return
      }

      do {
        let planned = try await self.planner.route(from: origin, to: candidate, mode: self.mode)
        self.beginNavigating(planned, to: candidate)
      } catch {
        self.fail(error.localizedDescription)
      }
    }
  }

  private func beginNavigating(_ planned: PlannedRoute, to candidate: PlaceCandidate) {
    route = planned
    progress = RouteProgress(line: planned.line)
    averageSpeed = planned.totalTimeSeconds > 0
      ? planned.totalDistanceMeters / planned.totalTimeSeconds
      : 0
    destination = candidate
    var guide = TurnByTurn(route: planned)
    let opening = guide.begin()
    self.guide = guide

    phase = .navigating
    DebugLog.write("phase: navigating")
    destinationName = candidate.name
    status = "Guiding"
    isListening = false
    offRouteFixes = 0
    lastReroute = .distantPast

    nextInstruction = planned.maneuvers.first?.instruction ?? "Head toward \(candidate.name)"
    distanceToTurn = DistanceFormat.short(planned.totalDistanceMeters)
    remainingText = "\(DistanceFormat.short(planned.totalDistanceMeters)) · \(DistanceFormat.arrival(from: Date(), after: planned.totalTimeSeconds))"
    arrivalText = DistanceFormat.arrival(from: Date(), after: planned.totalTimeSeconds)

    location.startNavigating()

    var lines = ["Starting navigation to \(candidate.name)."]
    for event in opening {
      if case .speak(let line) = event { lines.append(line) }
    }
    say(lines.joined(separator: " "))
  }

  // MARK: - Driving along

  private func handle(position: GeoPoint) {
    guard phase == .navigating, var guide = self.guide, let route = self.route else {
      return
    }

    let events = guide.update(position)
    self.guide = guide

    if let meters = guide.metersToNextManeuver(from: position) {
      distanceToTurn = DistanceFormat.short(meters)
    }

    updateRemaining(from: position)

    for event in events {
      switch event {
      case .speak(let line):
        say(line)
      case .arrived:
        arrive()
        return
      }
    }

    // Off the route for a few fixes in a row means the route is stale, not that the
    // wearer is wrong. Ask for a new one.
    let distanceFromRoute = Geo.meters(from: position, toNearestOf: route.line)
    if distanceFromRoute > 90 {
      offRouteFixes += 1
    } else {
      offRouteFixes = 0
    }

    if offRouteFixes >= 3, !isReplanning, Date().timeIntervalSince(lastReroute) > 25 {
      offRouteFixes = 0
      lastReroute = Date()
      replan()
    }
  }

  /// Keeps the "left" and "arrive" tiles counting down instead of frozen at the route's
  /// original length.
  private func updateRemaining(from position: GeoPoint) {
    guard let progress else { return }
    let left = progress.remaining(from: position)
    let seconds = left / max(averageSpeed, 0.1)
    remainingText = "\(DistanceFormat.short(left)) · \(DistanceFormat.arrival(from: Date(), after: seconds))"
    arrivalText = DistanceFormat.arrival(from: Date(), after: seconds)
  }

  private func replan() {
    guard let destination else { return }
    isReplanning = true
    say("Rerouting.")

    Task { [weak self] in
      guard let self else { return }
      defer { self.isReplanning = false }

      guard let origin = await self.location.currentPoint(timeout: 5) else { return }

      do {
        let planned = try await self.planner.route(
          from: origin,
          to: destination,
          mode: self.mode
        )
        self.route = planned
        var guide = TurnByTurn(route: planned)
        let opening = guide.begin()
        self.guide = guide
        self.nextInstruction = planned.maneuvers.first?.instruction ?? "Continue"
        self.remainingText = DistanceFormat.short(planned.totalDistanceMeters)
        self.arrivalText = DistanceFormat.arrival(
          from: Date(),
          after: planned.totalTimeSeconds
        )

        // Say where to go now, not just that a new route exists. Joined into one
        // utterance, because starting a second one would cut the first off.
        let lines = opening.compactMap { event -> String? in
          if case .speak(let line) = event { return line }
          return nil
        }
        if !lines.isEmpty {
          self.say(lines.joined(separator: " "))
        }
      } catch {
        // Keep the old route rather than leaving the wearer with nothing.
      }
    }
  }

  private func arrive() {
    let name = destinationName
    location.startStayingAlive()
    phase = .idle
    guide = nil
    route = nil
    progress = nil
    destination = nil
    nextInstruction = ""
    distanceToTurn = ""
    remainingText = ""
    isListening = linkState.isReady
    status = "You have arrived"
    say("You have arrived at \(name).")
  }

  // MARK: - Commands

  func stopNavigation() {
    guard phase == .navigating else { return }
    location.startStayingAlive()
    phase = .idle
    guide = nil
    route = nil
    progress = nil
    destination = nil
    nextInstruction = ""
    distanceToTurn = ""
    remainingText = ""
    isListening = linkState.isReady
    status = "Stopped"
  }

  func repeatInstruction() {
    guard phase == .navigating, let guide else { return }
    guard let maneuver = guide.currentManeuver else { return }
    if maneuver.kind == .arrive {
      say("You are almost there.")
    } else {
      say(maneuver.instruction)
    }
  }

  /// Hands the trip to Google Maps or Apple Maps, for when the wearer would rather have
  /// the full map than the voice.
  func openInMaps() {
    guard let destination else { return }

    if let google = MapsLinks.googleMapsURL(destination: destination.point, mode: mode),
      UIApplication.shared.canOpenURL(google)
    {
      UIApplication.shared.open(google)
      return
    }

    let apple = MapsLinks.appleMapsURL(
      destination: destination.point,
      name: destination.name,
      mode: mode
    )
    UIApplication.shared.open(apple)
  }

  func dismissError() {
    let authorization = location.authorizationStatus
    locationDenied = authorization == .denied || authorization == .restricted
    phase = .idle
    status = linkState.isReady ? "Listening" : Self.describe(linkState)
    isListening = linkState.isReady
  }

  /// True when the only way forward is for the wearer to change a setting.
  var needsLocationSettings: Bool { locationDenied }

  func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  // MARK: - Speaking

  /// Says one line, with the glasses microphone off so the app never hears itself.
  private func say(_ text: String, then completion: (() -> Void)? = nil) {
    isSpeaking = true
    link.pauseListening()

    speaker.speak(text) { [weak self] in
      guard let self else { return }
      self.isSpeaking = false
      // The microphone comes back on now; give the last of the sound a moment to die
      // away so the app does not hear its own tail.
      self.ignoreTranscriptsUntil = Date().addingTimeInterval(0.4)
      if self.linkState.isReady {
        self.link.resumeListening()
        self.isListening = true
      }
      completion?()
    }
  }

  private func fail(_ message: String) {
    phase = .failed(message)
    status = message
    isListening = linkState.isReady
    // Nothing is being guided, so drop back to the low-power check.
    location.startStayingAlive()
    say(message)
  }

  // MARK: - Helpers

  private static func readOut(_ candidates: [PlaceCandidate]) -> String {
    let names = candidates.map(\.name)
    switch names.count {
    case 0: return ""
    case 1: return names[0] + "."
    case 2: return "\(names[0]) and \(names[1])."
    default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1] + "."
    }
  }

  private static func describe(_ state: GlassesLink.State) -> String {
    switch state {
    case .starting: return "Starting up"
    case .notRegistered: return "Connect your glasses"
    case .waitingForGlasses: return "Waiting for your glasses"
    case .connecting: return "Connecting"
    case .needsMicrophonePermission: return "Allow the microphone in Meta AI"
    case .ready: return "Listening"
    case .failed(let message): return message
    }
  }
}
