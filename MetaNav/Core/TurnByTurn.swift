import Foundation

/// One thing the wearer has to do, and where they have to do it.
struct Maneuver: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case depart
    case turn
    case arrive
  }

  /// What to say, already written as a sentence ("Turn right onto Main Street").
  var instruction: String
  /// Where the maneuver happens.
  var point: GeoPoint
  /// How long the leg leading to this maneuver is.
  var distanceMeters: Double
  var kind: Kind

  /// How far away this maneuver is announced. Short legs get less warning so the
  /// announcements do not pile up on top of each other.
  var announceAtMeters: Double {
    switch kind {
    case .arrive: return 60
    case .depart: return 0
    case .turn:
      if distanceMeters < 70 { return 35 }
      if distanceMeters < 250 { return 90 }
      if distanceMeters < 800 { return 180 }
      return 250
    }
  }
}

enum TurnEvent: Equatable, Sendable {
  case speak(String)
  case arrived
}

/// A planned trip, as the app needs it: an ordered list of maneuvers plus the line on the
/// map used to notice when the wearer has left the route.
struct PlannedRoute: Equatable, Sendable {
  var maneuvers: [Maneuver]
  var line: [GeoPoint]
  var destination: GeoPoint
  var destinationName: String
  var totalDistanceMeters: Double
  var totalTimeSeconds: Double
  var mode: TravelMode
}

/// Walks a planned route alongside the wearer's position and decides what to say.
///
/// Pure on purpose: it takes a position and returns words, so the whole turn-by-turn
/// behaviour can be tested without a phone, glasses, or road.
struct TurnByTurn {
  private let maneuvers: [Maneuver]
  private(set) var index: Int = 0
  private var announced: Set<Int> = []
  private(set) var hasArrived = false

  init(route: PlannedRoute) {
    self.maneuvers = route.maneuvers
  }

  init(maneuvers: [Maneuver]) {
    self.maneuvers = maneuvers
  }

  var currentManeuver: Maneuver? {
    guard index < maneuvers.count else { return nil }
    return maneuvers[index]
  }

  /// The opening line, said before the first position fix arrives.
  mutating func begin() -> [TurnEvent] {
    guard let first = currentManeuver else { return [] }
    switch first.kind {
    case .arrive:
      // Nothing useful to say: the destination is right there.
      return []
    case .depart, .turn:
      announced.insert(0)
      return [.speak(first.instruction)]
    }
  }

  /// Feed a position, get back whatever should be said right now.
  mutating func update(_ position: GeoPoint) -> [TurnEvent] {
    guard !hasArrived, !maneuvers.isEmpty else { return [] }

    var events: [TurnEvent] = []

    // Move on once the next maneuver is closer than the one we are waiting for. The
    // maneuvers are the turn points, so being nearer to the next one means the current
    // one is already behind — which is how a missed turn or a GPS gap gets noticed
    // without needing the full route geometry.
    while index + 1 < maneuvers.count {
      let here = Geo.meters(from: position, to: maneuvers[index].point)
      let next = Geo.meters(from: position, to: maneuvers[index + 1].point)
      if next < here {
        index += 1
      } else {
        break
      }
    }

    let maneuver = maneuvers[index]
    let distance = Geo.meters(from: position, to: maneuver.point)

    if maneuver.kind == .arrive {
      if distance <= 45 {
        hasArrived = true
        events.append(.arrived)
      }
      return events
    }

    if !announced.contains(index), distance <= maneuver.announceAtMeters {
      announced.insert(index)
      let spokenDistance = DistanceFormat.spoken(distance)
      // "In now, turn right" is not a sentence. When the turn is right there, drop
      // the distance and just say the turn.
      let prefix = maneuver.kind == .turn && spokenDistance != "now"
        ? "In \(spokenDistance), "
        : ""
      events.append(.speak(prefix + lowerFirst(maneuver.instruction)))
    }

    return events
  }

  /// How far the wearer is from the route line right now.
  func distanceFromRoute(_ position: GeoPoint, line: [GeoPoint]) -> Double {
    Geo.meters(from: position, toNearestOf: line)
  }

  /// The distance to the maneuver being waited for, for the on-screen readout.
  func metersToNextManeuver(from position: GeoPoint) -> Double? {
    guard let maneuver = currentManeuver, maneuver.kind != .arrive else { return nil }
    return Geo.meters(from: position, to: maneuver.point)
  }

  /// "Turn right onto Main Street" → "turn right onto Main Street", so it can follow
  /// "In 200 meters, ".
  private func lowerFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.lowercased() + text.dropFirst()
  }
}
