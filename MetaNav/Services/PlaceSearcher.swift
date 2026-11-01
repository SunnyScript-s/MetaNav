import Foundation
import MapKit

/// Turns a spoken place name into a short list of real places.
///
/// Apple's local search is used instead of a web API: it needs no key, no billing
/// account, and no sign-up, which is the difference between "works on your phone
/// today" and "works after you register a card".
struct PlaceSearcher {
  enum SearchError: LocalizedError {
    case noResults(String)
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .noResults(let query): return "I couldn't find \(query)."
      case .failed: return "The place search did not answer."
      }
    }
  }

  /// How many options to keep. Three is as many as anyone wants read out loud.
  static let maximumOptions = 3

  func search(_ query: String, near center: GeoPoint?) async throws -> [PlaceCandidate] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query

    if let center {
      request.region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
        latitudinalMeters: 40_000,
        longitudinalMeters: 40_000
      )
    }

    let response: MKLocalSearch.Response
    do {
      response = try await MKLocalSearch(request: request).start()
    } catch {
      throw SearchError.failed(error.localizedDescription)
    }

    var items = response.mapItems
    guard !items.isEmpty else { throw SearchError.noResults(query) }

    // Closest first, so "the first one" is the one the wearer probably meant.
    if let center {
      items.sort {
        Geo.meters(from: center, to: $0.placemark.coordinate.geoPoint)
          < Geo.meters(from: center, to: $1.placemark.coordinate.geoPoint)
      }
    }

    return items.prefix(Self.maximumOptions).enumerated().map { offset, item in
      PlaceCandidate(
        id: offset,
        name: item.name ?? query.capitalized,
        detail: Self.detail(for: item),
        point: item.placemark.coordinate.geoPoint
      )
    }
  }

  private static func detail(for item: MKMapItem) -> String {
    let placemark = item.placemark
    var parts: [String] = []
    if let thoroughfare = placemark.thoroughfare {
      if let number = placemark.subThoroughfare {
        parts.append("\(number) \(thoroughfare)")
      } else {
        parts.append(thoroughfare)
      }
    }
    if let locality = placemark.locality, locality != placemark.thoroughfare {
      parts.append(locality)
    }
    if parts.isEmpty, let title = placemark.title {
      return title
    }
    return parts.joined(separator: ", ")
  }
}

extension CLLocationCoordinate2D {
  var geoPoint: GeoPoint {
    GeoPoint(latitude: latitude, longitude: longitude)
  }
}

extension GeoPoint {
  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }
}
