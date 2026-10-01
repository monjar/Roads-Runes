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
    /// The way back to the route while off it: worked out here, so it is there
    /// whether or not a new route can be fetched.
    private(set) var rejoin: RejoinGuide?
    /// Why the last attempt at a new route came to nothing, for the card to say.
    private(set) var rerouteError: String?
    /// A new route was just taken; true for a few seconds, for the card to say so.
    private(set) var recentReroute = false
    private(set) var lastFix: LocationFix?
    /// A stop the rider asked for that they are near right now, so the ride can say
    /// "your café is 90 m away" rather than leaving them to spot it going past.
    private(set) var nearbyStop: RoutePOI?
    private var arrivedStops: Set<UUID> = []
    /// The nearest chest, piece or monster and how the fight is going; claims are
    /// provisional until the summary says.
    private(set) var encounter: EncounterStatus?
    private(set) var recentClaim: WorldObject?
    private(set) var newTerritoryMeters: Double = 0
    /// A line for the screen about something that otherwise shows nothing there
    /// (what is on the way, a new place, halfway), for a few seconds.
    private(set) var notice: String?
    /// The chests, pieces and monsters still to be had, for the ride map.
    private(set) var objectsOnMap: [WorldObject] = []
    /// What has happened on this ride, in order: what the chimes and the voice were given.
    private(set) var eventLog: [RideEvent] = []
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
    @ObservationIgnored private var encounterTracker: EncounterTracker?
    @ObservationIgnored private var exploration: ExplorationRecorder?
    @ObservationIgnored private var rerouteAdvisor = RerouteAdvisor()
    @ObservationIgnored private var rerouteTask: Task<Void, Never>?
    @ObservationIgnored private var rerouteTicker: Task<Void, Never>?
    @ObservationIgnored private var rerouteToastTask: Task<Void, Never>?
    /// Answers that arrived for a place the rider had already left, in a row.
    @ObservationIgnored private var staleReroutes = 0
    /// When the last fix arrived by the wall clock, to tell the fixes' time while none are arriving.
    @ObservationIgnored private var lastFixReceivedAt = Date()
    @ObservationIgnored private var pendingPoints: [RidePoint] = []
    @ObservationIgnored private var pendingObjectiveEvents: [ObjectiveEvent] = []
    @ObservationIgnored private var sequence = 0
    @ObservationIgnored private var lastPersist: Date = .distantPast
    @ObservationIgnored private var lastHeartRate: Int?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var bikeId: UUID?
    @ObservationIgnored private var knownCells: Set<String> = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var announcer = RideAnnouncer()
    @ObservationIgnored private var milestones: RideMilestones?
    @ObservationIgnored private var newGround = NewGroundRun()
    @ObservationIgnored private var sighted: Set<UUID> = []
    @ObservationIgnored private var metMonsters: Set<UUID> = []
    /// Pieces picked up on this ride that the player did not already hold, by set.
    @ObservationIgnored private var piecesTaken: [String: Set<String>] = [:]
    /// Places near the route the rider has not found yet, and the ones already called out.
    @ObservationIgnored private var unfoundPlaces: [DiscoverySummary] = []
    @ObservationIgnored private var announcedPlaces: Set<UUID> = []
    private let audio: RideAudio

    init(api: any RoadsAndRunesAPI, location: LocationService, health: HealthKitService, watch: WatchSessionService, sync: SyncService,
         persistence: PersistenceService, cellIndexing: H3CellIndexing, activeRideStore: FileActiveRideStore, routePackages: FileRoutePackageStore,
         analytics: AnalyticsSink, session: SessionStore, audio: RideAudio) {
        self.audio = audio
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
        audio.onFinishedSpeaking = { [weak self] in
            guard let self else { return }
            self.announcer.finishedSpeaking(at: self.fixClockNow)
            self.sayNext()
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
        resetEvents()
        milestones = RideMilestones(route: package.route)
        transition(to: .ready)
        configureTrackers(for: package, start: location.lastFix?.coordinate ?? package.route.path.first ?? package.route.instructions.first?.coordinate)
        await loadEncounters(around: location.lastFix?.coordinate ?? package.route.path.first)
        await loadUnfoundPlaces(for: package)
        audio.start()

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
        // What the route has on it, said once before the first turn.
        emit(.briefing(for: objectsOnMap, along: package.route.path), at: startedAt)
        checkStartIsOnRoute()
    }

    func pause() {
        // A new route being fetched is given up: it would be for where they stopped.
        if state == .rerouting {
            cancelReroute()
            _ = transition(to: .offRoute)
        }
        guard transition(to: .paused) else { return }
        stopRerouteTicker()
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
        cancelReroute()
        stopRerouteTicker()
        if state == .rerouting { _ = transition(to: .offRoute) }
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
            objectiveEvents: pendingObjectiveEvents, healthKitWorkoutId: workoutId,
            encounterEvents: encounterTracker?.pendingEvents ?? []
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
        cancelReroute()
        stopRerouteTicker()
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
        encounterTracker = nil
        encounter = nil
        recentClaim = nil
        exploration = nil
        audio.stop()
        notice = nil
        objectsOnMap = []
        milestones = nil
        unfoundPlaces = []
        offRouteSince = nil
        rejoin = nil
        rerouteError = nil
        recentReroute = false
        isRerouting = false
        recoverableRide = nil
    }

    // MARK: - Fix handling (spec §35, §36)

    func handle(fix: LocationFix) {
        guard isActive, state == .active || state == .offRoute || state == .rerouting else { return }
        var enriched = fix
        enriched.heartRate = lastHeartRate
        lastFix = enriched
        lastFixReceivedAt = Date()
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
                // New ground sings: each cell never ridden is the next note up.
                for cell in entered where !recorder.knownCells.contains(cell) {
                    emit(.newGround(run: newGround.entered(at: enriched.timestamp)), at: enriched.timestamp)
                }
            }
            if let batch = recorder.takePendingBatch(now: enriched.timestamp) {
                Task { await self.uploadCells(batch, recorder: recorder) }
            }
        }
        if var tracker = progressTracker {
            let update = tracker.update(position: enriched.coordinate)
            progressTracker = tracker
            progress = update
            handleOffRoute(update, from: enriched.coordinate, at: enriched.timestamp)
            for event in milestones?.update(progress: update) ?? [] { emit(event, at: enriched.timestamp) }
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
        if var tracker = encounterTracker {
            let result = tracker.update(
                position: enriched.coordinate, timestamp: enriched.timestamp, altitude: enriched.altitude,
                elevationGainMeters: stats.elevationGainMeters
            )
            encounterTracker = tracker
            encounter = result.status
            for object in result.claimed { handle(claimed: object, at: enriched.coordinate) }
            noteSightings(result.status, tracker: tracker, from: enriched.coordinate, at: enriched.timestamp)
        }
        notePlaces(from: enriched.coordinate, at: enriched.timestamp)
        sayNext()
        if pendingPoints.count >= Config.pointsUploadBatchSize {
            let batch = pendingPoints
            pendingPoints = []
            Task { await self.uploadPoints(batch) }
        }
        sendWatchUpdate()
        persist()
    }

    /// The chests, pieces and monsters around the start, for live feedback on the way.
    private func loadEncounters(around coordinate: Coordinate?) async {
        guard let coordinate else { return }
        let objects = (try? await api.worldObjects(near: coordinate, radiusMeters: 8000)) ?? []
        encounterTracker = EncounterTracker(objects: objects, activity: activity)
        objectsOnMap = objects.filter { $0.status == .spawned }
    }

    /// Places near the route that the rider has not found, so passing one can be
    /// said at the time and not only read on the summary afterwards.
    private func loadUnfoundPlaces(for package: RoutePackage) async {
        let box = package.mapRegion
        let centre = Coordinate(latitude: (box.minLat + box.maxLat) / 2, longitude: (box.minLon + box.maxLon) / 2)
        let reach = GeoMath.distance(centre, Coordinate(latitude: box.maxLat, longitude: box.maxLon)) + 300
        let asked = Set(package.pois.filter { $0.requested == true }.map(\.discoveryId))
        let nearby = (try? await api.discoveries(near: centre, radiusMeters: min(20_000, reach), category: nil, limit: 100, cursor: nil))?.items ?? []
        // The stops the rider asked for have their own card when they come up.
        unfoundPlaces = nearby.filter { !$0.discoveredByUser && !asked.contains($0.id) }
    }

    // MARK: - Events: what the ride says

    /// The same reach the server uses to decide a place was found on a ride.
    private static let placeFoundMeters = 60.0

    private func resetEvents() {
        eventLog = []
        announcer = RideAnnouncer()
        newGround = NewGroundRun()
        sighted = []
        metMonsters = []
        piecesTaken = [:]
        announcedPlaces = []
        unfoundPlaces = []
        notice = nil
    }

    /// One thing happened: it is chimed, queued to be said, noted on screen if the
    /// screen would otherwise show nothing, and kept in the log.
    private func emit(_ event: RideEvent, at now: Date) {
        if case .briefing(let chests, let pieces, let monsters) = event, chests + pieces + monsters.count == 0 { return }
        eventLog.append(event)
        if eventLog.count > 400 { eventLog.removeFirst(eventLog.count - 400) }
        if let chime = event.chime { audio.play(chime, step: event.chimeStep) }
        if audio.mode == .voice {
            announcer.offer(event, units: units, at: now)
            sayNext()
        }
        if let line = event.pill(units: units) { show(notice: line) }
    }

    private func sayNext() {
        guard audio.mode == .voice, let line = announcer.nextLine(now: fixClockNow, isSpeaking: audio.isSpeaking) else { return }
        audio.speak(line)
    }

    private func show(notice line: String) {
        notice = line
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Something coming into sight is said once; a monster met and then left behind
    /// unbeaten is said too, where it used to vanish from the screen without a word.
    private func noteSightings(_ nearest: EncounterStatus?, tracker: EncounterTracker, from position: Coordinate, at now: Date) {
        if let nearest, !nearest.claimed, !sighted.contains(nearest.object.id) {
            sighted.insert(nearest.object.id)
            emit(.sighted(name: Self.shortName(nearest.object), kind: nearest.object.kind, meters: nearest.distanceMeters, method: nearest.method ?? nearest.object.monster?.killMethods.first?.method), at: now)
        }
        for object in tracker.objects where object.kind == .monster && !tracker.claimedIDs.contains(object.id) {
            let distance = GeoMath.distance(position, object.coordinate)
            if distance <= EncounterTracker.monsterNearMeters {
                metMonsters.insert(object.id)
            } else if distance > EncounterTracker.inSightMeters, metMonsters.remove(object.id) != nil {
                emit(.lost(name: object.name), at: now)
            }
        }
        metMonsters.subtract(tracker.claimedIDs)
    }

    private func notePlaces(from position: Coordinate, at now: Date) {
        for place in unfoundPlaces where !announcedPlaces.contains(place.id) && GeoMath.distance(position, place.coordinate) <= Self.placeFoundMeters {
            announcedPlaces.insert(place.id)
            emit(.newPlace(name: place.name), at: now)
        }
    }

    /// "Raido", not "Raido (Old Runes)": the set is said separately.
    private static func shortName(_ object: WorldObject) -> String {
        object.kind == .collectable ? (object.piece ?? object.name) : object.name
    }

    /// A chest passed or a monster beaten, as far as the phone can tell: the quest
    /// objective that points at it completes provisionally, the Watch buzzes, and
    /// the summary has the last word.
    private func handle(claimed object: WorldObject, at position: Coordinate) {
        recentClaim = object
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.recentClaim?.id == object.id { self?.recentClaim = nil }
        }
        if var tracker = objectiveTracker, let quest {
            for objective in quest.objectives where !completedObjectiveIDs.contains(objective.id) {
                let pointsAtIt = objective.extra?["objectId"]?.stringValue == object.id.uuidString
                let kindMatches = objective.extra?["kind"]?.stringValue == object.kind.rawValue
                let wants: Bool = {
                    switch objective.objectiveType {
                    case .slayMonster: return object.kind == .monster && (pointsAtIt || objective.extra?["objectId"] == nil)
                    case .openChest: return object.kind == .chest && (pointsAtIt || kindMatches)
                    case .collect: return object.kind == .collectable
                    default: return false
                    }
                }()
                guard wants, let event = tracker.markCompleted(objective.id, at: position, timestamp: Date()) else { continue }
                objectiveTracker = tracker
                handle(objectiveEvents: [event])
            }
        }
        let verb = object.kind == .monster ? "Beaten" : (object.kind == .chest ? "Opened" : "Found")
        objectsOnMap.removeAll { $0.id == object.id }
        // A second piece of a set found on the same ride counts on from the first, and
        // a second of the very same piece counts for nothing.
        var standing = object.setStanding
        if let setId = object.setId, let piece = object.piece, let before = standing {
            if object.pieceOwned != true { piecesTaken[setId, default: []].insert(piece) }
            standing = SetStanding(name: before.name, owned: min(before.of, before.owned + (piecesTaken[setId]?.count ?? 0)), of: before.of)
        }
        emit(.claimed(name: Self.shortName(object), kind: object.kind, coins: object.rewardAC, set: standing), at: lastFix?.timestamp ?? Date())
        watch.send(objectiveCompleted: WatchObjectiveCompleted(title: "\(verb): \(object.name)", coins: object.rewardAC, detail: standing?.line))
        analytics.track(.worldObjectClaimed, properties: ["kind": object.kind.rawValue, "name": object.name])
    }

    /// The Scribe's way past a monster: a note (and, for anyone else, a photo) within reach of it.
    func complete(encounter object: WorldObject, note: String?, photoTaken: Bool) {
        guard var tracker = encounterTracker else { return }
        guard tracker.markLore(object.id, at: location.lastFix?.coordinate, timestamp: Date(), note: note, photoTaken: photoTaken) != nil else { return }
        encounterTracker = tracker
        handle(claimed: object, at: location.lastFix?.coordinate ?? object.coordinate)
        encounter = nil
    }

    private var encounterLine: String? {
        guard let encounter else { return nil }
        let distance = Int(encounter.distanceMeters.rounded())
        if let progress = encounter.progress, let method = encounter.method {
            return "\(encounter.object.name) · \(distance) m · \(method.rawValue.lowercased()) \(Int(progress * 100))%"
        }
        return "\(encounter.object.name) · \(distance) m"
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
                let left = quest.requiredObjectives.filter { !completedObjectiveIDs.contains($0.id) && $0.status != .completed }.count
                emit(.objectiveCompleted(title: objective.title, remaining: left), at: event.occurredAt)
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

    // MARK: - Off route and rerouting

    /// Past this far from the first stretch of a new route, the route is for somewhere
    /// the rider has already left.
    private static let staleRerouteMeters = 60.0
    private static let maxStaleReroutes = 2

    private func handleOffRoute(_ update: ProgressUpdate, from position: Coordinate, at now: Date) {
        rerouteAdvisor.observe(isOffRoute: update.isOffRoute, at: now)
        if update.isOffRoute {
            if state == .active {
                _ = transition(to: .offRoute)
                AppLog.navigation.info("off_route \(Int(update.crossTrackDistance), privacy: .public) m")
                emit(.offRoute, at: now)
                startRerouteTicker()
            }
            offRouteSince = rerouteAdvisor.offRouteSince
            rejoin = RejoinGuide(from: position, to: update.snappedPosition)
            considerReroute(now: now)
        } else if state == .offRoute || state == .rerouting {
            // Back on it under their own steam: a new route still on its way is not wanted.
            cancelReroute()
            stopRerouteTicker()
            offRouteSince = nil
            rejoin = nil
            rerouteError = nil
            _ = transition(to: .active)
            AppLog.navigation.info("back_on_route")
        }
    }

    /// The rider started somewhere the route is not. Nothing would say so until
    /// they had moved three fixes' worth, and a rider waiting to be shown the way
    /// does not move.
    private func checkStartIsOnRoute() {
        guard let here = location.lastFix, abs(here.timestamp.timeIntervalSinceNow) < 30, var tracker = progressTracker else { return }
        var update = tracker.update(position: here.coordinate)
        guard update.crossTrackDistance >= RerouteAdvisor.farMeters else { return }
        for _ in 1..<RouteProgressTracker.offRouteConsecutiveUpdates { update = tracker.update(position: here.coordinate) }
        progressTracker = tracker
        progress = update
        lastFix = here
        lastFixReceivedAt = Date()
        handleOffRoute(update, from: here.coordinate, at: here.timestamp)
    }

    /// "Now", on the fixes' own clock: the time of the last one plus however long ago it came.
    private var fixClockNow: Date {
        guard let lastFix else { return Date() }
        return lastFix.timestamp.addingTimeInterval(Date().timeIntervalSince(lastFixReceivedAt))
    }

    private func considerReroute(now: Date) {
        guard isActive, state == .offRoute, rerouteTask == nil, let position = lastFix?.coordinate else { return }
        guard rerouteAdvisor.shouldReroute(now: now, crossTrackMeters: progress?.crossTrackDistance ?? 0) else { return }
        startReroute(from: position, at: now)
    }

    /// The rider asked for a new route themselves: no waiting on the clock.
    func rerouteNow() {
        guard isActive, state == .offRoute, rerouteTask == nil, let position = lastFix?.coordinate else { return }
        rerouteAdvisor.clearThrottle()
        startReroute(from: position, at: fixClockNow)
    }

    private func startReroute(from position: Coordinate, at now: Date) {
        guard let package, transition(to: .rerouting) else { return }
        isRerouting = true
        rerouteError = nil
        rerouteAdvisor.markRerouted(at: now)
        analytics.track(.routeReroute, properties: ["routeId": package.route.id.uuidString])
        let request = RerouteRequest(
            origin: position,
            progressMeters: progress?.distanceAlongRoute ?? 0,
            completedObjectiveIds: Array(completedObjectiveIDs),
            visitedStopIds: Array(arrivedStops)
        )
        let routeId = package.route.id
        let api = self.api
        rerouteTask = Task { [weak self] in
            let result: Result<RouteOption, Error>
            do {
                result = .success(try await api.reroute(routeId: routeId, request))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishReroute(result, askedFrom: position)
        }
    }

    private func finishReroute(_ result: Result<RouteOption, Error>, askedFrom origin: Coordinate) {
        rerouteTask = nil
        isRerouting = false
        // Paused, finished or back on the route while it was on its way.
        guard isActive, state == .rerouting else { return }
        switch result {
        case .failure(let error):
            rerouteFailed(error.localizedDescription)
        case .success(let route):
            guard route.path.count >= 2 else { return rerouteFailed("The route that came back was empty") }
            // Only if they have moved: a rider standing in a park is as near to this
            // route's first road as any other answer would put them.
            if let here = lastFix?.coordinate, staleReroutes < Self.maxStaleReroutes,
               GeoMath.distance(here, origin) > Self.staleRerouteMeters {
                var probe = RouteProgressTracker(route: route)
                if probe.update(position: here).crossTrackDistance > Self.staleRerouteMeters {
                    // They kept moving while it was drawn: this is the way from where they
                    // were. Ask again from where they are, at once.
                    staleReroutes += 1
                    AppLog.navigation.info("reroute_stale")
                    _ = transition(to: .offRoute)
                    rerouteAdvisor.clearThrottle()
                    startReroute(from: here, at: fixClockNow)
                    return
                }
            }
            adopt(route)
        }
    }

    private func rerouteFailed(_ reason: String) {
        AppLog.navigation.warning("reroute_failed \(reason, privacy: .public)")
        rerouteAdvisor.markFailed()
        rerouteError = "Couldn't get a new route"
        _ = transition(to: .offRoute)
    }

    private func adopt(_ route: RouteOption) {
        guard let package else { return }
        let newPackage = RoutePackage(route: route, quest: package.quest, pois: route.pois, mapRegion: route.boundingBox ?? package.mapRegion, generatedAt: Date())
        try? routePackages.save(newPackage)
        self.package = newPackage
        var tracker = RouteProgressTracker(route: route)
        if let here = lastFix?.coordinate { progress = tracker.update(position: here) }
        progressTracker = tracker
        rerouteAdvisor.markSucceeded()
        staleReroutes = 0
        offRouteSince = nil
        rejoin = nil
        rerouteError = nil
        stopRerouteTicker()
        _ = transition(to: .active)
        AppLog.navigation.info("rerouted \(Int(route.distanceMeters), privacy: .public) m")
        milestones?.retarget(route: route)
        emit(.rerouted, at: lastFix?.timestamp ?? Date())
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        recentReroute = true
        rerouteToastTask?.cancel()
        rerouteToastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.recentReroute = false
        }
        sendWatchSummary()
        sendWatchUpdate(force: true)
        persist(force: true)
    }

    private func cancelReroute() {
        rerouteTask?.cancel()
        rerouteTask = nil
        isRerouting = false
        staleReroutes = 0
    }

    /// Fixes are filtered by distance, so a rider who stops to look at the map sends
    /// none, and the decision to reroute was only ever made when one arrived. This
    /// makes it on a clock as well, for as long as they are off the route.
    private func startRerouteTicker() {
        guard rerouteTicker == nil else { return }
        rerouteTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                guard self.isActive, self.state == .offRoute || self.state == .rerouting else {
                    self.rerouteTicker = nil
                    return
                }
                self.considerReroute(now: self.fixClockNow)
            }
        }
    }

    private func stopRerouteTicker() {
        rerouteTicker?.cancel()
        rerouteTicker = nil
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
            latitude: lastFix?.coordinate.latitude, longitude: lastFix?.coordinate.longitude,
            encounterLine: encounterLine, newTerritoryMeters: newTerritoryMeters,
            remainingMeters: state == .active ? progress?.distanceRemaining : nil
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
