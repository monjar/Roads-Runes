import CoreLocation
import Foundation
import RoadsAndRunesCore

/// CoreLocation wrapper. Produces `LocationFix` values; accuracy and distance
/// filter follow `BatteryPolicy` but never drop below the navigation minimum.
@MainActor
final class LocationService: NSObject, ObservableObject {
    enum Authorization { case notDetermined, denied, whenInUse, always }

    @Published private(set) var authorization: Authorization = .notDetermined
    @Published private(set) var lastFix: LocationFix?
    @Published private(set) var heading: Double?
    @Published private(set) var accuracyPoor = false

    var onFix: ((LocationFix) -> Void)?

    private let manager = CLLocationManager()
    private var tracking = false
    private let analytics: AnalyticsSink

    init(analytics: AnalyticsSink) {
        self.analytics = analytics
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        updateAuthorization(manager.authorizationStatus)
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Requested only when a ride starts (spec §74).
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    func startTracking(mode: BatteryMode) {
        apply(mode: mode)
        manager.allowsBackgroundLocationUpdates = authorization == .always
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        tracking = true
    }

    func startPassive() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        manager.allowsBackgroundLocationUpdates = false
        manager.startUpdatingLocation()
        tracking = false
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        tracking = false
    }

    func apply(mode: BatteryMode) {
        let policy = BatteryPolicy.policy(for: mode)
        manager.desiredAccuracy = min(policy.desiredAccuracyMeters, BatteryPolicy.minimumNavigationAccuracyMeters)
        manager.distanceFilter = policy.distanceFilterMeters
    }

    private func updateAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways: authorization = .always
        case .authorizedWhenInUse: authorization = .whenInUse
        case .denied, .restricted: authorization = .denied
        default: authorization = .notDetermined
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.updateAuthorization(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { location -> LocationFix in
            LocationFix(
                coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                timestamp: location.timestamp,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                speed: location.speed >= 0 ? location.speed : nil,
                heartRate: nil
            )
        }
        Task { @MainActor in
            for fix in fixes {
                self.lastFix = fix
                let poor = (fix.horizontalAccuracy ?? 0) > 50
                if poor != self.accuracyPoor {
                    self.accuracyPoor = poor
                    if poor { self.analytics.track(.gpsAccuracyPoor, properties: ["accuracy": String(Int(fix.horizontalAccuracy ?? 0))]) }
                }
                self.onFix?(fix)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.heading = value }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient errors (kCLErrorLocationUnknown) are expected in tunnels; keep tracking.
    }
}
