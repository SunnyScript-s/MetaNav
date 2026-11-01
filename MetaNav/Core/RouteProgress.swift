import Foundation

/// How far along a route the wearer is, and how much of it is left.
///
/// The "left" readout cannot be the route's original length: that never changes, so it
/// would still say "1.5 km" with the destination in sight. This walks the route's own line
/// instead, which gives a number that counts down the way a passenger expects.
struct RouteProgress: Equatable, Sendable {
  private let line: [GeoPoint]
  /// Metres from the start of the line to each of its points.
  private let cumulative: [Double]

  /// The length of the whole route.
  let total: Double

  init(line: [GeoPoint]) {
    self.line = line

    var running: Double = 0
    var distances: [Double] = []
    distances.reserveCapacity(line.count)
    for (offset, point) in line.enumerated() {
      if offset > 0 {
        running += Geo.meters(from: line[offset - 1], to: point)
      }
      distances.append(running)
    }
    self.cumulative = distances
    self.total = running
  }

  /// Metres still to travel from `position`, measured along the route.
  ///
  /// The nearest point on the line is taken as "where the wearer is", so a fix a few
  /// metres to the side of the road does not jump the count backwards or forwards.
  func remaining(from position: GeoPoint) -> Double {
    guard !line.isEmpty else { return 0 }
    guard line.count > 1 else { return Geo.meters(from: position, to: line[0]) }

    var nearest = 0
    var best = Double.greatestFiniteMagnitude
    for (offset, point) in line.enumerated() {
      let distance = Geo.meters(from: position, to: point)
      if distance < best {
        best = distance
        nearest = offset
      }
    }

    let left = total - cumulative[nearest] + best
    return max(0, min(total, left))
  }
}
