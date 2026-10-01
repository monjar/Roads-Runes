import CoreLocation
import Foundation
import Observation
import RoadsAndRunesCore

/// CoreLocation wrapper. Produces `LocationFix` values; accuracy and distance
/// filter follow `BatteryPolicy` but never drop below the navigation minimum.
///
/// Observable, so a view that reads `lastFix` is drawn again when the player
/// moves: "30 m away" and "within reach" are only true of where they are now.
/// (It published through Combine before, which no view subscribed to.)
@MainActor
@Observable
final class LocationService: NSObject {
    enum Authorization { case notDetermined, denied, whenInUse, always }

    private(set) var authorization: Authorization = .notDetermined
    private(set) var lastFix: LocationFix?
    private(set) var heading: Double?
    private(set) var accuracyPoor = false

    @ObservationIgnored var onFix: ((LocationFix) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private let analytics: AnalyticsSink
    /// False in tests and previews: the manager is never started, so a simulator's
    /// own idea of where it is (San Francisco) cannot arrive in the middle of a
    /// scripted ride. Fixes come only from whoever calls the recorder.
    @ObservationIgnored private let live: Bool

    init(analytics: AnalyticsSink, live: Bool = true) {
        self.analytics = analytics
        self.live = live
        super.init()
        guard live else { return }
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        updateAuthorization(manager.authorizationStatus)
    }

    func requestWhenInUse() {
        guard live else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Requested only when a ride starts (spec §74).
    func requestAlways() {
        guard live else { return }
        manager.requestAlwaysAuthorization()
    }

    func startTracking(mode: BatteryMode) {
        guard live else {
            tracking = true
            return
        }
        apply(mode: mode)
        manager.allowsBackgroundLocationUpdates = authorization == .always
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        tracking = true
    }

    func startPassive() {
        // A ride has the manager: the map behind it must not turn its accuracy down.
        guard live, !tracking else { return }
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
        manager.allowsBackgroundLocationUpdates = false
        manager.startUpdatingLocation()
        tracking = false
    }

    /// The World map open in the hand: close enough to tell thirty metres from
    /// fifty, which the passive hundred-metre fix cannot, and often enough that
    /// walking up to a chest is seen. Only while the map is on screen.
    func startBrowsing() {
        guard live, !tracking else { return }
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 5
        manager.allowsBackgroundLocationUpdates = false
        manager.startUpdatingLocation()
    }

    func stop() {
        guard live else {
            tracking = false
            return
        }
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        manager.allowsBackgroundLocationUpdates = false
        tracking = false
    }

    func apply(mode: BatteryMode) {
        guard live else { return }
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
