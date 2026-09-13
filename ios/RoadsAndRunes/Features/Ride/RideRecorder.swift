import Foundation
import Observation
import RoadsAndRunesCore
import UIKit

/// Local-first ride engine (spec §34–36, §71–72). The phone is the source of
/// truth during the ride; nothing here waits on the network.
@MainActor
@Observable
final class RideRecorder {
    // Published state
    var isActive = false
    private(set) var state: NavigationState = .ready
    private(set) var package: RoutePackage?
    private(set) var quest: Quest?
    private(set) var ride: Ride?
    private(set) var clientRideId = UUID()
    private(set) var stats = RideSnapshot()
    private(set) var progress: ProgressUpdate?
    /// Custom adventure name (spec §31); quest rides are named by the quest.
    private(set) var title: String?
    private(set) var currentObjective: Objective?
    /// How this outing is being done; sets the workout, the ride record and the words on screen.
    private(set) var activity: Activity = .ride
    private(set) var completedObjectiveIDs: Set<UUID> = []
    private(set) var recentObjectiveCompletion: Objective?
    private(set) var offRouteSince: Date?
    private(set) var isRerouting = false
    private(set) var lastFix: LocationFix?
    /// A stop the rider asked for that they are near right now, so the ride can say
    /// "your café is 90 m away" rather than leaving them to spot it going past.
    private(set) var nearbyStop: RoutePOI?
    private var arrivedStops: Set<UUID> = []
    private(set) var newTerritoryMeters: Double = 0
    private(set) var localCellStates: [String: CellState] = [:]
    var recoverableRide: ActiveRideState?

    // Dependencies
    private let api: any RoadsAndRunesAPI
    private let location: LocationService
    private let health: HealthKitService
    private let watch: WatchSessionService
    private let sync: SyncService
    private let persistence: PersistenceService
    private let cellIndexing: H3CellIndexing
    private let activeRideStore: FileActiveRideStore
    private let routePackages: FileRoutePackageStore
    private let analytics: AnalyticsSink
    private let session: SessionStore

    // Engine internals
    @ObservationIgnored private var machine = NavigationStateMachine()
    @ObservationIgnored private var statistics = RideStatistics()
    @ObservationIgnored private var progressTracker: RouteProgressTracker?
    @ObservationIgnored private var objectiveTracker: ObjectiveTracker?
    @ObservationIgnored private var exploration: ExplorationRecorder?
    @ObservationIgnored private var rerouteAdvisor = RerouteAdvisor()
    @ObservationIgnored private var pendingPoints: [RidePoint] = []
    @ObservationIgnored private var pendingObjectiveEvents: [ObjectiveEvent] = []
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var lastPersist: Date = .distantPast
    @ObservationIgnored private var lastHeartRate: Int?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var bikeId: UUID?
    @ObservationIgnored private var knownCells: Set<String> = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(api: any RoadsAndRunesAPI, location: LocationService, health: HealthKitService, watch: WatchSessionService, sync: SyncService,
         persistence: PersistenceService, cellIndexing: H3CellIndexing, activeRideStore: FileActiveRideStore, routePackages: FileRoutePackageStore,
         analytics: AnalyticsSink, session: SessionStore) {
        self.api = api
        self.location = location
        self.health = health
        self.watch = watch
        self.sync = sync
        self.persistence = persistence
        self.cellIndexing = cellIndexing
        self.activeRideStore = activeRideStore
        self.routePackages = routePackages
        self.analytics = analytics
        self.session = session
        location.onFix = { [weak self] fix in
            Task { @MainActor in self?.handle(fix: fix) }
        }
    }

    var units: Units { session.units }
    var batteryMode: BatteryMode { session.settings.batteryMode == .unknown ? .balanced : session.settings.batteryMode }

    /// Cells the world view last reported as known; used so new territory is counted correctly.
    func setKnownCells(_ cells: Set<String>) {
        knownCells = cells
    }

    // MARK: - Lifecycle

    func start(package: RoutePackage, quest: Quest?, bikeId: UUID?, title: String? = nil, activity: Activity = .ride) async {
        guard !isActive else { return }
        self.activity = activity == .unknown ? .ride : activity
        try? routePackages.save(package)
        self.package = package
        self.quest = quest ?? package.quest
        self.bikeId = bikeId
        self.title = self.quest == nil ? title : nil
        clientRideId = UUID()
        startedAt = Date()
        sequence = 0
        pendingPoints = []
        pendingObjectiveEvents = []
        completedObjectiveIDs = []
        newTerritoryMeters = 0
        localCellStates = [:]
        statistics = RideStatistics()
        stats = statistics.snapshot
        machine = NavigationStateMachine()
        rerouteAdvisor = RerouteAdvisor()
        transition(to: .ready)
        configureTrackers(for: package, start: location.lastFix?.coordinate ?? package.route.path.first ?? package.route.instructions.first?.coordinate)

        if location.authorization != .always { location.requestAlways() }
        await health.requestAuthorization()
        health.beginWorkout(startDate: startedAt, activity: self.activity)
        location.startTracking(mode: batteryMode)
        watch.configure(batteryMode: batteryMode)

        persistence.upsertActiveRide(clientRideId: clientRideId, serverRideId: nil, questId: self.quest?.id, routeId: package.route.id, bikeId: bikeId, startedAt: startedAt, state: .active)
        ride = try? await api.createRide(RideCreate(
            clientRideId: clientRideId, startedAt: startedAt, questId: self.quest?.id, bikeId: bikeId, routeId: package.route.id, title: self.title,
            activity: self.activity
        ))
        if let ride { persistence.upsertActiveRide(clientRideId: clientRideId, serverRideId: ride.id, questId: self.quest?.id, routeId: package.route.id, bikeId: bikeId, startedAt: startedAt, state: .active) }

        transition(to: .active)
        isActive = true
        analytics.track(.rideStarted, properties: ["questId": self.quest?.id.uuidString ?? "none"])
        analytics.track(.navigationStarted, properties: ["routeId": package.route.id.uuidString])
        sendWatchSummary()
        persist(force: true)
    }

    func pause() {
        guard transition(to: .paused) else { return }
        location.apply(mode: .endurance)
        sendWatchUpdate(force: true)
        persist(force: true)
    }

    func resume() {
        guard transition(to: .active) else { return }
        location.startTracking(mode: batteryMode)
        sendWatchUpdate(force: true)
        persist(force: true)
    }

    func finish() async {
        guard isActive || state == .recovery else { return }
        _ = transition(to: .finishing)
        location.stop()
        let endedAt = Date()
        let workoutId = await health.endWorkout(endDate: endedAt)
        stats = statistics.snapshot
        var cells = exploration?.takePendingBatch(now: endedAt, force: true) ?? []
        cells.append(contentsOf: pendingCellsFromStore())
        let completion = RideComplete(
            endedAt: endedAt, distanceMeters: stats.distanceMeters, durationSeconds: Int(stats.elapsedSeconds), movingSeconds: Int(stats.movingSeconds),
            elevationGainMeters: stats.elevationGainMeters, activeCalories: nil, points: pendingPoints, cellsVisited: Array(Set(cells)),
            objectiveEvents: pendingObjectiveEvents, healthKitWorkoutId: workoutId
        )
        pendingPoints = []
        pendingObjectiveEvents = []
        await ensureServerRide()
        await sync.completeRide(rideId: ride?.id, rideClientId: clientRideId, completion: completion)
        analytics.track(.navigationEnded, properties: ["distance": String(Int(stats.distanceMeters))])
        _ = transition(to: .completed)
        sendWatchUpdate(force: true)
        cleanup()
    }

    func discard() {
        location.stop()
        health.discard()
        _ = transition(to: .cancelled)
        sendWatchUpdate(force: true)
        cleanup()
    }

    private func cleanup() {
        try? activeRideStore.clear()
        persistence.deleteActiveRide(clientRideId: clientRideId)
        isActive = false
        package = nil
        nearbyStop = nil
        arrivedStops = []
        quest = nil
        progress = nil
        currentObjective = nil
        progressTracker = nil
        objectiveTracker = nil
        exploration = nil
        offRouteSince = nil
        recoverableRide = nil
    }

    // MARK: - Fix handling (spec §35, §36)

    func handle(fix: LocationFix) {
        guard isActive, state == .active || state == .offRoute || state == .rerouting else { return }
        var enriched = fix
        enriched.heartRate = lastHeartRate
        lastFix = enriched
        updateNearbyStop(from: enriched.coordinate)
        let accepted = statistics.add(fix: enriched)
        stats = statistics.snapshot
        if accepted {
            persistence.append(fix: enriched, rideClientId: clientRideId, sequence: sequence)
            sequence += 1
            pendingPoints.append(enriched.ridePoint)
            health.record(fix: enriched)
            health.update(distanceMeters: stats.distanceMeters, activeCalories: nil, at: enriched.timestamp)
        }
        if let recorder = exploration {
            let entered = recorder.record(fix: enriched)
            if !entered.isEmpty {
                for cell in entered { localCellStates[cell] = recorder.localState(for: cell) }
                newTerritoryMeters = recorder.newTerritoryMeters
            }
            if let batch = recorder.takePendingBatch(now: enriched.timestamp) {
                Task { await self.uploadCells(batch, recorder: recorder) }
            }
        }
        if var tracker = progressTracker {
            let update = tracker.update(position: enriched.coordinate)
            progressTracker = tracker
            progress = update
            handleOffRoute(update.isOffRoute, at: enriched.timestamp)
        }
        if var tracker = objectiveTracker {
            let events = tracker.update(
                position: enriched.coordinate,
                distanceMeters: stats.distanceMeters,
                elevationGainMeters: stats.elevationGainMeters,
                newTerritoryMeters: newTerritoryMeters,
                elapsedSeconds: stats.elapsedSeconds,
                timestamp: enriched.timestamp
            )
            objectiveTracker = tracker
            if !events.isEmpty { handle(objectiveEvents: events) }
            currentObjective = tracker.pendingObjectives.first
        }
        if pendingPoints.count >= Config.pointsUploadBatchSize {
            let batch = pendingPoints
            pendingPoints = []
            Task { await self.uploadPoints(batch) }
        }
        sendWatchUpdate()
        persist()
    }

    func record(heartRate bpm: Int) {
        lastHeartRate = bpm
    }

    /// Scribe objectives the GPS cannot judge: the rider photographs or writes.
    /// The photograph stays on the device (there is no photo storage yet); the
    /// note goes to the discovery the objective belongs to.
    func complete(objective: Objective, note: String? = nil, photo: Data? = nil) async {
        guard var tracker = objectiveTracker else { return }
        let event = tracker.markCompleted(objective.id, at: location.lastFix?.coordinate, timestamp: Date())
        objectiveTracker = tracker
        guard let event else { return }
        handle(objectiveEvents: [event])
        currentObjective = tracker.pendingObjectives.first
        if let photo { store(photo: photo, for: objective) }
        if let note, !note.isEmpty, let discoveryId = objective.discoveryId {
            _ = try? await api.updateUserDiscovery(id: discoveryId, UserDiscoveryIn(note: note))
        }
        persist(force: true)
    }

    private func store(photo: Data, for objective: Objective) {
        let directory = AppContainer.storageDirectory()
            .appendingPathComponent("RidePhotos/\(clientRideId.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? photo.write(to: directory.appendingPathComponent("\(objective.id.uuidString).jpg"))
    }

    private func handle(objectiveEvents events: [ObjectiveEvent]) {
        guard let quest else { return }
        pendingObjectiveEvents.append(contentsOf: events)
        for event in events {
            completedObjectiveIDs.insert(event.objectiveId)
            if let objective = quest.objectives.first(where: { $0.id == event.objectiveId }) {
                showObjectiveToast(objective)
                watch.send(objectiveCompleted: WatchObjectiveCompleted(title: objective.title, xp: nil))
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let batch = events
        Task { await self.sync.reportQuestProgress(questId: quest.id, rideClientId: self.clientRideId, events: batch) }
    }

    private func showObjectiveToast(_ objective: Objective) {
        recentObjectiveCompletion = objective
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.recentObjectiveCompletion = nil
        }
    }

    private func handleOffRoute(_ offRoute: Bool, at now: Date) {
        rerouteAdvisor.observe(isOffRoute: offRoute, at: now)
        if offRoute {
            if state == .active { _ = transition(to: .offRoute) }
            offRouteSince = rerouteAdvisor.offRouteSince
            if rerouteAdvisor.shouldReroute(now: now), !isRerouting {
                Task { await self.reroute(from: lastFix?.coordinate) }
            }
        } else if state == .offRoute || state == .rerouting {
            offRouteSince = nil
            _ = transition(to: .active)
        }
    }

    // MARK: - Rerouting

    private func reroute(from origin: Coordinate?) async {
        guard let origin, let package, !isRerouting else { return }
        isRerouting = true
        _ = transition(to: .rerouting)
        rerouteAdvisor.markRerouted(at: Date())
        analytics.track(.routeReroute, properties: ["routeId": package.route.id.uuidString])
        defer { isRerouting = false }
        do {
            let response = try await api.generateRoutes(RouteGenerateRequest(origin: origin, bikeId: bikeId, questId: quest?.id, distanceTargetKm: max(5, (package.route.distanceMeters - stats.distanceMeters) / 1000), loop: quest != nil))
            guard let best = response.alternatives.first else { return }
            let newPackage = RoutePackage(route: best, quest: package.quest, pois: best.pois, mapRegion: best.boundingBox ?? package.mapRegion, generatedAt: Date())
            try? routePackages.save(newPackage)
            self.package = newPackage
            progressTracker = RouteProgressTracker(route: best)
            sendWatchSummary()
            _ = transition(to: .active)
        } catch {
            AppLog.navigation.warning("reroute_failed \(error.localizedDescription, privacy: .public)")
            _ = transition(to: .offRoute)
        }
    }

    // MARK: - Uploads

    private func ensureServerRide() async {
        guard ride == nil else { return }
        ride = try? await api.createRide(RideCreate(
            clientRideId: clientRideId, startedAt: startedAt, questId: quest?.id, bikeId: bikeId, routeId: package?.route.id, title: title,
            activity: activity
        ))
        if let ride { persistence.upsertActiveRide(clientRideId: clientRideId, serverRideId: ride.id, questId: quest?.id, routeId: package?.route.id, bikeId: bikeId, startedAt: startedAt, state: state) }
    }

    private func uploadPoints(_ batch: [RidePoint]) async {
        await ensureServerRide()
        guard let rideId = ride?.id else {
            pendingPoints.insert(contentsOf: batch, at: 0)
            return
        }
        await sync.uploadPoints(rideId: rideId, rideClientId: clientRideId, points: batch)
    }

    private func uploadCells(_ batch: [String], recorder: ExplorationRecorder) async {
        await ensureServerRide()
        guard let rideId = ride?.id else {
            recorder.requeue(batch)
            return
        }
        await sync.uploadCells(rideId: rideId, rideClientId: clientRideId, cells: batch)
        recorder.markUploaded(batch)
    }

    private func pendingCellsFromStore() -> [String] {
        (try? activeRideStore.load())?.pendingCells ?? []
    }

    // MARK: - Watch

    private func sendWatchSummary() {
        guard let package else { return }
        let objectives = (quest?.sortedObjectives ?? []).map { WatchObjective(objective: $0) }
        let stops = package.pois.prefix(12).map {
            WatchStop(id: $0.discoveryId, name: $0.name, latitude: $0.latitude, longitude: $0.longitude, requested: $0.requested == true)
        }
        watch.send(
            summary: WatchRouteSummary(
                questTitle: quest?.title,
                instructions: package.route.instructions,
                objectives: objectives,
                totalDistanceMeters: package.route.distanceMeters,
                routeCoordinates: Self.thinned(package.route.coordinates),
                stops: Array(stops),
                activity: activity.rawValue
            ),
            units: units
        )
    }

    /// A route can be thousands of points; a watch screen is 200 across and the
    /// message has to fit in a WatchConnectivity payload. Keep every nth point, and
    /// always the last one so the line ends where the ride does.
    static func thinned(_ coordinates: [[Double]], limit: Int = 160) -> [[Double]] {
        guard coordinates.count > limit else { return coordinates }
        let stride = Int((Double(coordinates.count) / Double(limit)).rounded(.up))
        var thinned = coordinates.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        if let last = coordinates.last, thinned.last != last { thinned.append(last) }
        return thinned
    }

    private func sendWatchUpdate(force: Bool = false) {
        let nextText: String? = {
            guard let package, let current = progress?.nextInstruction else { return nil }
            return package.route.instructions.first { $0.index > current.index }?.text
        }()
        var objectiveDistance: Double?
        if let objective = currentObjective, let target = objective.coordinate, let position = lastFix?.coordinate {
            objectiveDistance = GeoMath.distance(position, target)
        }
        let update = WatchNavigationUpdate(
            state: state, instruction: progress?.nextInstruction, distanceToInstructionMeters: progress?.distanceToNextInstruction,
            nextInstructionText: nextText, objectiveTitle: currentObjective?.title, objectiveDistanceMeters: objectiveDistance,
            distanceMeters: stats.distanceMeters, elapsedSeconds: stats.elapsedSeconds, elevationGainMeters: stats.elevationGainMeters,
            heartRate: stats.lastHeartRateBpm, speedMps: stats.currentSpeedMps,
            latitude: lastFix?.coordinate.latitude, longitude: lastFix?.coordinate.longitude
        )
        watch.send(update: update, force: force)
    }

    // MARK: - Persistence & recovery (spec §72)

    private func persist(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPersist) >= Config.ridePersistInterval else { return }
        lastPersist = now
        let snapshot = ActiveRideState(
            rideId: ride?.id, clientRideId: clientRideId, questId: quest?.id, routeId: package?.route.id, bikeId: bikeId,
            navigationState: state, startedAt: startedAt, updatedAt: now, stats: stats,
            pendingCells: exploration?.pendingUpload ?? [], visitedCells: Array(exploration?.visitedCells ?? []),
            completedObjectiveIDs: Array(completedObjectiveIDs), pendingObjectiveEvents: pendingObjectiveEvents,
            lastFix: lastFix, lastSegmentIndex: progress?.nearestSegmentIndex ?? 0, title: title, activity: activity.rawValue
        )
        try? activeRideStore.save(snapshot)
        persistence.save()
    }

    func recoverIfNeeded() {
        guard !isActive, let saved = try? activeRideStore.load(), saved.needsRecovery else { return }
        recoverableRide = saved
        analytics.track(.navigationCrashed, properties: ["clientRideId": saved.clientRideId.uuidString])
    }

    func resumeRecovered() async {
        guard let saved = recoverableRide else { return }
        recoverableRide = nil
        clientRideId = saved.clientRideId
        startedAt = saved.startedAt
        bikeId = saved.bikeId
        title = saved.title
        activity = saved.activity.flatMap(Activity.init(rawValue:)) ?? .ride
        statistics = RideStatistics(resuming: saved.stats)
        stats = statistics.snapshot
        completedObjectiveIDs = Set(saved.completedObjectiveIDs)
        pendingObjectiveEvents = saved.pendingObjectiveEvents
        sequence = persistence.pointCount(rideClientId: clientRideId)
        machine = NavigationStateMachine(state: .recovery)
        state = .recovery
        if let routeId = saved.routeId, let package = try? routePackages.load(routeId: routeId) {
            self.package = package
            quest = package.quest
            configureTrackers(for: package, start: saved.lastFix?.coordinate ?? package.route.path.first)
            exploration?.restore(visitedCells: saved.visitedCells, pendingUpload: saved.pendingCells)
            progressTracker?.reset(toSegment: saved.lastSegmentIndex)
        }
        if let rideId = saved.rideId, let serverRide = try? await api.ride(id: rideId) { ride = serverRide }
        location.startTracking(mode: batteryMode)
        health.beginWorkout(startDate: Date())
        transition(to: .active)
        isActive = true
        sendWatchSummary()
    }

    func finishRecovered() async {
        guard let saved = recoverableRide else { return }
        recoverableRide = nil
        clientRideId = saved.clientRideId
        startedAt = saved.startedAt
        bikeId = saved.bikeId
        title = saved.title
        activity = saved.activity.flatMap(Activity.init(rawValue:)) ?? .ride
        ride = nil
        if let rideId = saved.rideId { ride = try? await api.ride(id: rideId) }
        statistics = RideStatistics(resuming: saved.stats)
        stats = statistics.snapshot
        pendingObjectiveEvents = saved.pendingObjectiveEvents
        pendingPoints = persistence.points(rideClientId: clientRideId, onlyPending: true).map {
            RidePoint(latitude: $0.latitude, longitude: $0.longitude, timestamp: $0.timestamp, altitudeMeters: $0.altitude, horizontalAccuracyMeters: $0.horizontalAccuracy, speedMps: $0.speed, heartRateBpm: $0.heartRate)
        }
        quest = nil
        if let routeId = saved.routeId, let package = try? routePackages.load(routeId: routeId) {
            self.package = package
            quest = package.quest
        }
        machine = NavigationStateMachine(state: .recovery)
        state = .recovery
        await finish()
    }

    func discardRecovered() {
        if let saved = recoverableRide { persistence.deleteActiveRide(clientRideId: saved.clientRideId) }
        recoverableRide = nil
        try? activeRideStore.clear()
    }

    // MARK: - Helpers

    @discardableResult
    private func transition(to target: NavigationState) -> Bool {
        do {
            try machine.transition(to: target)
            state = machine.state
            return true
        } catch {
            AppLog.navigation.debug("illegal_transition \(self.state.rawValue, privacy: .public) -> \(target.rawValue, privacy: .public)")
            return false
        }
    }

    /// Within this far, a stop is "here"; beyond it the card goes away again.
    private static let stopInSight: Double = 250
    private static let stopArrived: Double = 60

    /// The nearest stop the rider asked for that is within sight and not yet visited.
    /// Incidental places found along the route are not announced: they did not ask.
    private func updateNearbyStop(from coordinate: Coordinate) {
        let asked = (package?.pois ?? []).filter { $0.requested == true }
        guard !asked.isEmpty else { return }
        let closest = asked
            .map { ($0, GeoMath.distance(coordinate, $0.coordinate)) }
            .filter { $0.1 <= Self.stopInSight && !arrivedStops.contains($0.0.discoveryId) }
            .min { $0.1 < $1.1 }
        if let (poi, distance) = closest {
            if nearbyStop?.discoveryId != poi.discoveryId {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                analytics.track(.discoveryFound, properties: ["discoveryId": poi.discoveryId.uuidString, "requested": "true"])
            }
            nearbyStop = poi
            if distance <= Self.stopArrived { arrivedStops.insert(poi.discoveryId) }
        } else {
            nearbyStop = nil
        }
    }

    private func configureTrackers(for package: RoutePackage, start: Coordinate?) {
        progressTracker = RouteProgressTracker(route: package.route)
        let origin = start ?? package.route.path.first ?? Coordinate(latitude: 0, longitude: 0)
        if let quest = quest ?? package.quest {
            objectiveTracker = ObjectiveTracker(objectives: quest.objectives, start: origin)
            currentObjective = objectiveTracker?.pendingObjectives.first
        }
        exploration = ExplorationRecorder(indexing: cellIndexing, resolution: session.config?.h3Resolution ?? ExplorationDefaults.h3Resolution, knownCells: knownCells,
                                          batchSize: Config.explorationFlushCells, flushInterval: Config.explorationFlushInterval)
    }
}
