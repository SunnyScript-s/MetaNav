import Foundation
import MapKit

/// Turns "from here to there" into the maneuver list the voice guide walks through.
struct RoutePlanner {
  enum PlanError: LocalizedError {
    case noRoute
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .noRoute: return "I couldn't find a route there."
      case .failed: return "The route planner did not answer."
      }
    }
  }

  func route(
    from origin: GeoPoint,
    to candidate: PlaceCandidate,
    mode: TravelMode
  ) async throws -> PlannedRoute {
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
    request.destination = MKMapItem(
      placemark: MKPlacemark(coordinate: candidate.point.coordinate)
    )
    request.transportType = transportType(for: mode)
    request.requestsAlternateRoutes = false

    let response: MKDirections.Response
    do {
      response = try await MKDirections(request: request).calculate()
    } catch {
      throw PlanError.failed(error.localizedDescription)
    }

    guard let route = response.routes.first else { throw PlanError.noRoute }

    let maneuvers = Self.maneuvers(from: route, destinationName: candidate.name)
    guard maneuvers.count >= 1 else { throw PlanError.noRoute }

    return PlannedRoute(
      maneuvers: maneuvers,
      line: Self.line(from: route.polyline),
      destination: candidate.point,
      destinationName: candidate.name,
      totalDistanceMeters: route.distance,
      totalTimeSeconds: route.expectedTravelTime,
      mode: mode
    )
  }

  // MARK: - Building

  static func maneuvers(from route: MKRoute, destinationName: String) -> [Maneuver] {
    var result: [Maneuver] = []

    // The route's own line ends at the destination, which is where the arrival step has
    // to be measured from. A step's polyline *starts* at its maneuver.
    let arrivalPoint =
      lastPoint(of: route.polyline)
      ?? firstPoint(of: route.polyline)
      ?? GeoPoint(latitude: 0, longitude: 0)

    for (offset, step) in route.steps.enumerated() {
      let instruction = clean(step.instructions)
      let isLast = offset == route.steps.count - 1
      let point: GeoPoint = isLast
        ? arrivalPoint
        : (firstPoint(of: step.polyline) ?? step.polyline.coordinate.geoPoint)

      if instruction.isEmpty && !isLast { continue }

      let kind: Maneuver.Kind
      if isLast {
        kind = .arrive
      } else if result.isEmpty {
        // `offset == 0` would miss the case where Apple's first step has no words and
        // was skipped above.
        kind = .depart
      } else {
        kind = .turn
      }

      result.append(
        Maneuver(
          instruction: kind == .arrive
            ? "You have arrived at \(destinationName)."
            : instruction,
          point: point,
          distanceMeters: step.distance,
          kind: kind
        )
      )
    }

    // A route with only the arrival step still needs something to say at the start.
    if result.count == 1, result[0].kind == .arrive {
      result.insert(
        Maneuver(
          instruction: "Head toward \(destinationName).",
          point: route.steps.first.flatMap { firstPoint(of: $0.polyline) } ?? result[0].point,
          distanceMeters: route.distance,
          kind: .depart
        ),
        at: 0
      )
    }

    return result
  }

  static func line(from polyline: MKPolyline) -> [GeoPoint] {
    var coordinates = [CLLocationCoordinate2D](
      repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
      count: polyline.pointCount
    )
    polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
    return coordinates.map(\.geoPoint)
  }

  /// The first point of a polyline. `MKPolyline.coordinate` is the middle of the shape,
  /// which for a long step can be a long way from the turn it belongs to.
  static func firstPoint(of polyline: MKPolyline) -> GeoPoint? {
    guard polyline.pointCount > 0 else { return nil }
    var coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    polyline.getCoordinates(&coordinate, range: NSRange(location: 0, length: 1))
    return coordinate.geoPoint
  }

  static func lastPoint(of polyline: MKPolyline) -> GeoPoint? {
    guard polyline.pointCount > 0 else { return nil }
    var coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    polyline.getCoordinates(
      &coordinate,
      range: NSRange(location: polyline.pointCount - 1, length: 1)
    )
    return coordinate.geoPoint
  }

  /// Apple writes instructions like "Turn right onto Main St." — the trailing period is
  /// dropped because the speaker adds its own pauses.
  static func clean(_ instruction: String) -> String {
    var text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix(".") || text.hasSuffix(",") {
      text.removeLast()
    }
    return text
  }

  private func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
    switch mode {
    case .driving: return .automobile
    case .walking: return .walking
    case .cycling: return .walking
    case .transit: return .transit
    }
  }
}
