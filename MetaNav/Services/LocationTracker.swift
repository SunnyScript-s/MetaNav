import CoreLocation
import Foundation

/// Watches the phone's position and hands each fix to the guide.
///
/// Background updates are on so the app keeps guiding with the phone in a pocket and the
/// screen off — which is the only way this is useful while walking or riding.
@MainActor
final class LocationTracker: NSObject {
  private let manager = CLLocationManager()

  var onUpdate: ((GeoPoint) -> Void)?
  var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

  /// The last fix, so a request for "where am I" can answer immediately.
  private(set) var lastPoint: GeoPoint?
  private(set) var lastLocation: CLLocation?

  /// `authorizationStatus` can read `.denied` for a moment at launch, before locationd has
  /// answered. This says whether a real answer has arrived, so a transient reading is
  /// never mistaken for the wearer saying no.
  private(set) var hasSettledAuthorization = false

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    manager.distanceFilter = 5
    manager.activityType = .automotiveNavigation
    manager.pausesLocationUpdatesAutomatically = false
  }

  var authorizationStatus: CLAuthorizationStatus {
    manager.authorizationStatus
  }

  var hasPermission: Bool {
    #if os(iOS)
    return manager.authorizationStatus == .authorizedWhenInUse
      || manager.authorizationStatus == .authorizedAlways
    #else
    return manager.authorizationStatus == .authorizedAlways
    #endif
  }

  func requestPermission() {
    switch manager.authorizationStatus {
    case .notDetermined:
      manager.requestWhenInUseAuthorization()
    #if os(iOS)
    case .authorizedWhenInUse:
      // Asking for "always" is what keeps guidance alive when the screen locks.
      manager.requestAlwaysAuthorization()
    #endif
    default:
      break
    }
  }

  /// Full accuracy, for the length of a trip.
  func startNavigating() {
    if manager.authorizationStatus == .notDetermined {
      requestPermission()
    }
    manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    manager.distanceFilter = 5
    manager.activityType = .automotiveNavigation
    #if os(iOS)
    // Background updates are only legal with "Always". Setting this with only
    // "While Using" would stop the updates instead of helping.
    manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
    manager.showsBackgroundLocationIndicator = true
    #endif
    manager.startUpdatingLocation()
  }

  /// Low accuracy, between trips. This is what keeps the app running with the phone in a
  /// pocket, so the glasses can still be heard when nothing is being guided yet. It costs
  /// very little battery at this accuracy.
  func startStayingAlive() {
    guard hasPermission else { return }
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.distanceFilter = 100
    manager.activityType = .other
    #if os(iOS)
    manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
    manager.showsBackgroundLocationIndicator = true
    #endif
    manager.startUpdatingLocation()
  }

  func stop() {
    manager.stopUpdatingLocation()
  }

  /// Waits briefly for a usable fix, because the first one after starting can take a
  /// moment and a route needs a starting point.
  func currentPoint(timeout: TimeInterval = 6) async -> GeoPoint? {
    if let lastPoint, isFresh(lastLocation, within: 30) {
      return lastPoint
    }

    // Nothing is coming if the answer is already a settled no.
    if hasSettledAuthorization, !hasPermission { return nil }

    startNavigating()

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let point = lastPoint, isFresh(lastLocation, within: 20) {
        return point
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return lastPoint
  }

  private func isFresh(_ location: CLLocation?, within seconds: TimeInterval) -> Bool {
    guard let location else { return false }
    return abs(location.timestamp.timeIntervalSinceNow) < seconds
  }
}

extension LocationTracker: CLLocationManagerDelegate {
  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    guard let location = locations.last else { return }
    // Old cached fixes are worse than waiting for a fresh one.
    guard location.horizontalAccuracy >= 0, location.horizontalAccuracy < 100 else { return }

    Task { @MainActor in
      let point = location.coordinate.geoPoint
      self.lastPoint = point
      self.lastLocation = location
      self.onUpdate?(point)
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didChangeAuthorization status: CLAuthorizationStatus
  ) {
    Task { @MainActor in
      self.hasSettledAuthorization = true
      self.onAuthorizationChange?(status)
      #if os(iOS)
      if status == .authorizedWhenInUse {
        manager.requestAlwaysAuthorization()
      } else if status == .authorizedAlways {
        manager.allowsBackgroundLocationUpdates = true
      }
      #endif

      if self.hasPermission {
        self.startStayingAlive()
      }
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    // Transient failures are normal indoors; the next fix is usually fine.
  }
}
