import Foundation

/// One possible place the wearer might have meant.
struct PlaceCandidate: Equatable, Sendable, Identifiable {
  var id: Int
  var name: String
  /// Street address or neighbourhood, used to tell two similar names apart.
  var detail: String
  var point: GeoPoint

  /// What to say when reading the options out loud.
  var spokenLabel: String {
    detail.isEmpty ? name : "\(name), \(detail)"
  }
}
