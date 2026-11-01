import Foundation

/// A plain latitude/longitude pair.
///
/// Deliberately not `CLLocationCoordinate2D`: this keeps the routing logic free of
/// CoreLocation so it can be compiled and tested on its own.
struct GeoPoint: Equatable, Sendable {
  var latitude: Double
  var longitude: Double
}

enum Geo {
  /// Mean Earth radius in metres.
  static let earthRadius: Double = 6_371_008.8

  /// Straight-line distance between two points, in metres.
  static func meters(from a: GeoPoint, to b: GeoPoint) -> Double {
    let lat1 = a.latitude * .pi / 180
    let lat2 = b.latitude * .pi / 180
    let dLat = (b.latitude - a.latitude) * .pi / 180
    let dLon = (b.longitude - a.longitude) * .pi / 180

    let h = sin(dLat / 2) * sin(dLat / 2)
      + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
    return 2 * earthRadius * asin(min(1, sqrt(h)))
  }

  /// Shortest distance from `point` to any of `line`, in metres.
  static func meters(from point: GeoPoint, toNearestOf line: [GeoPoint]) -> Double {
    var best = Double.greatestFiniteMagnitude
    for candidate in line {
      let d = meters(from: point, to: candidate)
      if d < best { best = d }
    }
    return best
  }
}

enum DistanceFormat {
  /// How a distance is said out loud, the way a person would say it.
  static func spoken(_ meters: Double) -> String {
    if meters < 10 { return "now" }
    if meters < 1000 {
      let rounded = Int((meters / 10).rounded() * 10)
      return "\(rounded) meters"
    }
    let km = meters / 1000
    if km < 10 {
      let rounded = (km * 10).rounded() / 10
      return rounded == rounded.rounded()
        ? "\(Int(rounded)) kilometers"
        : String(format: "%.1f kilometers", rounded)
    }
    return "\(Int(km.rounded())) kilometers"
  }

  /// Short on-screen form, e.g. "250 m", "1.4 km".
  static func short(_ meters: Double) -> String {
    if meters < 1000 { return "\(Int((meters / 10).rounded() * 10)) m" }
    return String(format: "%.1f km", meters / 1000)
  }

  /// Rough arrival clock, e.g. "4:35 PM".
  static func arrival(from now: Date, after seconds: TimeInterval) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: now.addingTimeInterval(seconds))
  }
}
