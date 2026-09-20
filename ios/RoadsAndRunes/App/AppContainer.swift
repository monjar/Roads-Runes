import Foundation
import Observation
import RoadsAndRunesCore

/// Dependency container. Built once at launch and injected through the
/// SwiftUI environment; previews use `AppContainer.preview` (MockAPI).
@MainActor
@Observable
final class AppContainer {
    let api: any RoadsAndRunesAPI
    let session: SessionStore
    let location: LocationService
    let health: HealthKitService
    let analytics: AnalyticsSink
    let persistence: PersistenceService
    let cellIndexing: H3CellIndexing
    let routePackages: FileRoutePackageStore
    let activeRideStore: FileActiveRideStore
    let watch: WatchSessionService
    let sync: SyncService
    let rideRecorder: RideRecorder
    let mapPreferences: MapPreferencesStore
    let nudges: NudgeScheduler

    /// Pending Strava OAuth code delivered through the URL scheme.
    var pendingStravaCode: String?

    init(api: (any RoadsAndRunesAPI)? = nil, inMemory: Bool = false) {
        let analytics = OSLogAnalytics()
        let useMock = api == nil && (ProcessInfo.processInfo.environment["RR_MOCK_API"] == "1" || Self.isPreview)
        // UI tests (RR_UI_TEST=1) start every launch signed out, with nothing cached and no Health sheet.
        let uiTesting = Self.isUITesting
        let tokenStore = KeychainTokenStore()
        if uiTesting { tokenStore.clear() }
        let resolvedAPI: any RoadsAndRunesAPI = api ?? (useMock ? MockAPI() : APIClient(baseURL: Config.apiBaseURL, tokenStore: tokenStore))
        let directory = Self.storageDirectory()
        let persistence = PersistenceService(inMemory: inMemory || uiTesting)
        let location = LocationService(analytics: analytics)
        let health = HealthKitService(enabled: !inMemory && !uiTesting)
        let watch = WatchSessionService()
        let session = SessionStore(api: resolvedAPI)
        let routePackages = FileRoutePackageStore(directory: directory.appendingPathComponent("routes", isDirectory: true))
        let activeRideStore = FileActiveRideStore(directory: directory)
        if uiTesting { try? activeRideStore.clear() }
        let sync = SyncService(api: resolvedAPI, persistence: persistence, session: session, analytics: analytics)
        let recorder = RideRecorder(
            api: resolvedAPI, location: location, health: health, watch: watch, sync: sync, persistence: persistence,
            cellIndexing: H3CellIndexing(), activeRideStore: activeRideStore, routePackages: routePackages, analytics: analytics, session: session
        )
        self.api = resolvedAPI
        self.analytics = analytics
        self.persistence = persistence
        self.location = location
        self.health = health
        self.watch = watch
        self.session = session
        self.cellIndexing = H3CellIndexing()
        self.routePackages = routePackages
        self.activeRideStore = activeRideStore
        self.sync = sync
        self.rideRecorder = recorder
        self.mapPreferences = MapPreferencesStore()
        self.nudges = NudgeScheduler(active: !inMemory && !uiTesting && !Self.isPreview)
        watch.onCommand = { [weak recorder] command in
            Task { @MainActor in
                guard let recorder else { return }
                switch command {
                case .pause: recorder.pause()
                case .resume: recorder.resume()
                case .end: await recorder.finish()
                }
            }
        }
        watch.onHeartRate = { [weak recorder] bpm in
            Task { @MainActor in recorder?.record(heartRate: bpm) }
        }
        health.onHeartRate = { [weak recorder] bpm in
            Task { @MainActor in recorder?.record(heartRate: bpm) }
        }
    }

    func bootstrap() async {
        watch.activate()
        await session.bootstrap()
        rideRecorder.recoverIfNeeded()
        await sync.resumePendingUploads()
    }

    func handle(url: URL) {
        guard url.scheme == "roadsandrunes", url.host == "strava" else { return }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
        pendingStravaCode = code
    }

    static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["RR_UI_TEST"] == "1"
    }

    static func storageDirectory() -> URL {
        let fm = FileManager.default
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: Config.appGroup) {
            return group.appendingPathComponent("RoadsAndRunes", isDirectory: true)
        }
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return documents.appendingPathComponent("RoadsAndRunes", isDirectory: true)
    }

    @MainActor static let preview: AppContainer = AppContainer(api: MockAPI(), inMemory: true)
}

/// Client-side map/battery preferences persisted in UserDefaults; the server
/// copy in `UserSettings` is the source of truth when signed in.
@MainActor
@Observable
final class MapPreferencesStore {
    private let defaults = UserDefaults.standard

    var mapStyle: MapStyle {
        didSet { defaults.set(mapStyle.rawValue, forKey: "mapStyle") }
    }

    var batteryMode: BatteryMode {
        didSet { defaults.set(batteryMode.rawValue, forKey: "batteryMode") }
    }

    /// The dashed "?" rings for places not yet found. A city has hundreds; some riders
    /// want the map for the map.
    var showMysteries: Bool {
        didSet { defaults.set(showMysteries, forKey: "showMysteries") }
    }

    init() {
        showMysteries = defaults.object(forKey: "showMysteries") as? Bool ?? true
        mapStyle = MapStyle(rawValue: defaults.string(forKey: "mapStyle") ?? "") ?? .adventure
        batteryMode = BatteryMode(rawValue: defaults.string(forKey: "batteryMode") ?? "") ?? .balanced
    }

    func apply(settings: UserSettings) {
        if settings.mapStyle != .unknown { mapStyle = settings.mapStyle }
        if settings.batteryMode != .unknown { batteryMode = settings.batteryMode }
    }
}
