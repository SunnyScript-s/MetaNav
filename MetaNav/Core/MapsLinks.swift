import Foundation

/// Builds the hand-off URLs for Apple Maps and Google Maps.
///
/// Pure so the exact strings can be checked in tests; opening them is the caller's job.
enum MapsLinks {
  /// Apple Maps. `dirflg=d` is driving, `w` walking, `r` transit.
  static func appleMapsURL(
    destination: GeoPoint,
    name: String,
    mode: TravelMode
  ) -> URL {
    var components = URLComponents()
    components.scheme = "maps"
    components.host = ""
    components.queryItems = [
      URLQueryItem(name: "daddr", value: "\(destination.latitude),\(destination.longitude)"),
      URLQueryItem(name: "q", value: name),
      URLQueryItem(name: "dirflg", value: appleFlag(for: mode)),
    ]
    return components.url ?? URL(string: "maps://")!
  }

  /// Google Maps, if it is installed.
  static func googleMapsURL(
    destination: GeoPoint,
    mode: TravelMode
  ) -> URL? {
    var components = URLComponents()
    components.scheme = "comgooglemaps"
    components.queryItems = [
      URLQueryItem(name: "daddr", value: "\(destination.latitude),\(destination.longitude)"),
      URLQueryItem(name: "directionsmode", value: googleMode(for: mode)),
    ]
    return components.url
  }

  /// Google Maps on the web, for when the app is not installed.
  static func googleMapsWebURL(destination: GeoPoint, mode: TravelMode) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "www.google.com"
    components.path = "/maps/dir/"
    components.queryItems = [
      URLQueryItem(name: "api", value: "1"),
      URLQueryItem(name: "destination", value: "\(destination.latitude),\(destination.longitude)"),
      URLQueryItem(name: "travelmode", value: googleMode(for: mode)),
    ]
    return components.url
  }

  private static func appleFlag(for mode: TravelMode) -> String {
    switch mode {
    case .driving, .cycling: return "d"
    case .walking: return "w"
    case .transit: return "r"
    }
  }

  private static func googleMode(for mode: TravelMode) -> String {
    switch mode {
    case .driving: return "driving"
    case .walking: return "walking"
    case .cycling: return "bicycling"
    case .transit: return "transit"
    }
  }
}
