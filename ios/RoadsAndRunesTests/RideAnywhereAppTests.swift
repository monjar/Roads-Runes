import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// Ride anywhere (0.9.2): a journey with no route, from the first fix to Journey's end,
/// through a crash, and on the lock screen.
@MainActor
final class RideAnywhereAppTests: XCTestCase {
    private var clock: TimeInterval = 0

    override func setUp() async throws {
        clock = 0
        base = SampleData.referenceDate
    }

    /// When the fixes' clock starts: the sample date, or now for a test that ends a journey by its fixes.
    private var base = SampleData.referenceDate

    private func ride(_ recorder: RideRecorder, to coordinate: Coordinate, after seconds: TimeInterval = 20) {
        clock += seconds
        recorder.handle(fix: LocationFix(coordinate: coordinate, timestamp: base.addingTimeInterval(clock), altitude: 10,
                                         horizontalAccuracy: 5, speed: 5))
    }

    /// Fixes every 100 m from `start` for `meters`, heading `bearing`.
    private func ride(_ recorder: RideRecorder, from start: Coordinate, bearing: Double = 90, meters: Double) {
        for step in stride(from: 0.0, through: meters, by: 100) {
            ride(recorder, to: GeoMath.destination(from: start, bearingDegrees: bearing, distanceMeters: step))
        }
    }

    private func chest(_ name: String, at coordinate: Coordinate) -> WorldObject {
        WorldObject(id: UUID(), kind: .chest, latitude: coordinate.latitude, longitude: coordinate.longitude, name: name, rewardAC: 25,
                    expiresAt: Date().addingTimeInterval(86_400))
    }

    private func claims(_ recorder: RideRecorder, of name: String) -> Int {
        recorder.eventLog.filter { if case .claimed(let claimed, _, _, _) = $0 { return claimed == name } else { return false } }.count
    }

    private func eventually(_ what: String, timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    func testARoamStartsWithNoRouteAndEndsWithNoRouteOrQuest() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let start = SampleData.origin
        let onTheWay = chest("Old chest", at: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 500))
        api.place([onTheWay], replacing: true)
        let recorder = container.rideRecorder

        await recorder.startRoam(activity: .ride, bikeId: SampleData.bikeId)
        XCTAssertTrue(recorder.isActive)
        XCTAssertTrue(recorder.isRoaming)
        XCTAssertEqual(recorder.state, .active)
        XCTAssertNil(recorder.package)
        XCTAssertNil(recorder.quest)
        let created = try XCTUnwrap(api.rideCreates.last)
        XCTAssertNil(created.routeId)
        XCTAssertNil(created.questId)
        XCTAssertEqual(created.activity, .ride)

        // No fix when it started: the world round the rider comes with the first.
        ride(recorder, to: start)
        await eventually("the world round the first fix loaded") { recorder.roamWorldLoaded }
        XCTAssertEqual(recorder.objectsOnMap.map(\.id), [onTheWay.id])

        ride(recorder, from: start, meters: 1200)
        XCTAssertEqual(claims(recorder, of: "Old chest"), 1, "a chest on the way opens")
        XCTAssertGreaterThan(recorder.newTerritoryMeters, 0, "the tiles count on a roam")

        await recorder.finish()
        XCTAssertFalse(recorder.isActive)
        XCTAssertFalse(recorder.isRoaming)
        let completion = try XCTUnwrap(api.rideCompletions.last)
        XCTAssertFalse(completion.cellsVisited.isEmpty, "the explored tiles go with the journey")
        XCTAssertEqual(completion.encounterEvents?.map(\.objectId), [onTheWay.id])
        XCTAssertGreaterThan(completion.distanceMeters, 1000)
    }

    /// A roam started where a fix was already in hand loads its world before it begins.
    func testARoamWithAFixInHandLoadsItsWorldAtOnce() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let start = SampleData.origin
        let near = chest("Iron chest", at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 300))
        api.place([near], replacing: true)
        container.location.deliver(LocationFix(coordinate: start, timestamp: Date(), altitude: 10, horizontalAccuracy: 5, speed: 0))
        await container.rideRecorder.startRoam(activity: .walk, bikeId: nil)
        XCTAssertTrue(container.rideRecorder.roamWorldLoaded)
        XCTAssertEqual(container.rideRecorder.objectsOnMap.map(\.id), [near.id])
        XCTAssertEqual(api.rideCreates.last?.activity, .walk)
        container.rideRecorder.discard()
    }

    func testARoamIsPutBackAfterACrash() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let start = SampleData.origin
        let ahead = chest("Iron chest", at: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 1500))
        api.place([ahead], replacing: true)
        let recorder = container.rideRecorder
        await recorder.startRoam(activity: .ride, bikeId: nil)
        ride(recorder, to: start)
        await eventually("the world loaded") { recorder.roamWorldLoaded }
        ride(recorder, from: start, meters: 800)
        recorder.pause()  // saves at once

        let saved = try XCTUnwrap(container.activeRideStore.load())
        XCTAssertEqual(saved.roam, true)
        XCTAssertNil(saved.routeId)
        XCTAssertFalse(saved.visitedCells.isEmpty)
        XCTAssertNotNil(saved.game)

        // The app is gone; a fresh one finds the roam and resumes it.
        let fresh = AppContainer(api: MockAPI(), inMemory: true)
        try fresh.activeRideStore.save(saved)
        fresh.rideRecorder.recoverIfNeeded()
        XCTAssertEqual(fresh.rideRecorder.recoverableRide?.isRoam, true)
        await fresh.rideRecorder.resumeRecovered()
        let resumed = fresh.rideRecorder
        XCTAssertTrue(resumed.isActive)
        XCTAssertTrue(resumed.isRoaming)
        XCTAssertNil(resumed.package)
        XCTAssertTrue(resumed.roamWorldLoaded, "the world it had is put back, not fetched again")
        XCTAssertTrue(resumed.objectsOnMap.contains { $0.id == ahead.id })

        clock = 10_000
        ride(resumed, from: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 800), meters: 900)
        XCTAssertEqual(claims(resumed, of: "Iron chest"), 1, "what is ahead still opens")
        resumed.pause()
        let again = try XCTUnwrap(fresh.activeRideStore.load())
        XCTAssertEqual(again.roam, true)
        XCTAssertTrue(Set(again.visitedCells).isSuperset(of: saved.visitedCells), "the tiles from before the crash are kept")
        resumed.discard()
    }

    /// Something placed 7 km out after the start: not seen at first, joined once the
    /// rider is 1.5 km on, and opened on the way past.
    func testFurtherOnANewChestJoinsTheJourneyAndOpens() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        api.place([], replacing: true)
        let start = SampleData.origin
        let recorder = container.rideRecorder
        await recorder.startRoam(activity: .ride, bikeId: nil)
        ride(recorder, to: start)
        await eventually("the world round the start loaded") { recorder.roamWorldLoaded }
        XCTAssertTrue(recorder.objectsOnMap.isEmpty)

        let ahead = chest("Iron chest", at: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 7000))
        api.place([ahead])
        ride(recorder, from: start, meters: 1000)
        await eventually("the look again 90 s in") { api.aroundAsks.count == 1 }
        XCTAssertFalse(recorder.objectsOnMap.contains { $0.id == ahead.id }, "6.5 km off is beyond the world round the rider")
        ride(recorder, from: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 1100), meters: 1000)
        await eventually("1.5 km on, the world is asked for again and the chest joins") {
            recorder.objectsOnMap.contains { $0.id == ahead.id }
        }
        XCTAssertEqual(api.aroundAsks.count, 2)
        XCTAssertEqual(api.aroundAsks.last?.rideId, recorder.ride?.id, "for the journey under way, so the server may place things")
        XCTAssertEqual(container.worldCache.load()?.objects.contains { $0.id == ahead.id }, true, "kept for a stretch with no signal")

        // On past it: opened, as a chest there from the start would be.
        ride(recorder, from: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 2200), meters: 5200)
        XCTAssertEqual(claims(recorder, of: "Iron chest"), 1)
        recorder.discard()
    }

    /// No signal on the way: the ride backs off and keeps going on the world it has.
    func testWithNoSignalTheRoamBacksOff() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let start = SampleData.origin
        let recorder = container.rideRecorder
        await recorder.startRoam(activity: .ride, bikeId: nil)
        ride(recorder, to: start)
        await eventually("the world loaded") { recorder.roamWorldLoaded }
        api.aroundRefusal = .server(code: "FEATURE_DISABLED", message: "That isn't switched on yet.", status: 403)
        ride(recorder, from: start, meters: 600)
        await eventually("the ask failed") { recorder.roamRefresher.failures == 1 }
        XCTAssertTrue(recorder.isActive, "the journey goes on")
        let asked = api.aroundAsks.count
        ride(recorder, to: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 700), after: 10)
        XCTAssertEqual(api.aroundAsks.count, asked, "not asked again before the backoff")
        recorder.discard()
    }

    // MARK: - Left standing

    /// Twenty minutes still: the question, on the phone and for the Watch. "Keep
    /// going" takes it away; two hours still and the roam ends where it last moved.
    func testARoamLeftStandingIsAskedAboutThenEndsWhereItLastMoved() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let recorder = container.rideRecorder
        await recorder.startRoam(activity: .ride, bikeId: nil)
        // Fixes from now on: the journey ends at one of their times.
        base = Date()
        let start = SampleData.origin
        ride(recorder, from: start, meters: 1000)
        let lastMoved = base.addingTimeInterval(clock)
        XCTAssertEqual(recorder.idleWatch?.lastMovedAt, lastMoved)
        // A little drift where it stopped.
        ride(recorder, to: GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: 1010), after: 300)

        recorder.checkIdle(at: lastMoved.addingTimeInterval(19 * 60))
        XCTAssertFalse(recorder.stillOutPrompt)
        recorder.checkIdle(at: lastMoved.addingTimeInterval(20 * 60))
        XCTAssertTrue(recorder.stillOutPrompt, "Still out? End ride or keep going.")
        XCTAssertEqual(recorder.idleWatch?.savingBattery, true)
        recorder.keepGoing()
        XCTAssertFalse(recorder.stillOutPrompt)
        XCTAssertTrue(recorder.isActive)

        recorder.checkIdle(at: lastMoved.addingTimeInterval(2 * 3600))
        await eventually("the roam ended itself") { !recorder.isActive }
        let completion = try XCTUnwrap(api.rideCompletions.last)
        XCTAssertEqual(completion.endedAt, lastMoved, "trimmed to the last time it moved")
        XCTAssertTrue(completion.points.allSatisfy { $0.timestamp <= lastMoved }, "the drift after it stopped is left off")
    }

    /// A planned journey is only asked; it never ends itself.
    func testAPlannedJourneyLeftStandingIsOnlyAsked() async throws {
        let container = AppContainer(api: MockAPI(), inMemory: true)
        await container.session.bootstrap()
        let package = try await container.api.routePackage(id: SampleData.routeId)
        let recorder = container.rideRecorder
        await recorder.start(package: package, quest: nil, bikeId: nil)
        for point in package.route.path.prefix(3) { ride(recorder, to: point) }
        let lastMoved = base.addingTimeInterval(clock)
        recorder.checkIdle(at: lastMoved.addingTimeInterval(61 * 60))
        XCTAssertTrue(recorder.stillOutPrompt)
        recorder.checkIdle(at: lastMoved.addingTimeInterval(5 * 3600))
        XCTAssertTrue(recorder.isActive, "only a roam ends itself")
        // Moving again: the question goes.
        ride(recorder, to: package.route.path[8])
        XCTAssertFalse(recorder.stillOutPrompt)
        recorder.discard()
    }

    // MARK: - Entry points

    private func coordinator(_ api: MockAPI = MockAPI()) async -> (AppContainer, QuickStartCoordinator) {
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let coordinator = QuickStartCoordinator(container: container)
        coordinator.locate = { _ in SampleData.origin }
        coordinator.patience = .milliseconds(300)
        return (container, coordinator)
    }

    /// From the World tab, Siri or a link: the card says what it is, and nothing
    /// starts until Start. No route is asked for.
    func testRideAnywhereShowsItsCardAndStartsOnStart() async throws {
        let api = MockAPI()
        let (container, coordinator) = await coordinator(api)
        XCTAssertTrue(container.session.isEnabled(FeatureFlag.rideAnywhere), "the mock server has it on, for previews and UI tests")
        let outcome = await coordinator.run(.roam(activity: .run), autoStart: false)
        XCTAssertEqual(outcome, .ready)
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertNil(coordinator.plan, "nothing planned")
        XCTAssertEqual(coordinator.activity, .run)
        XCTAssertFalse(container.rideRecorder.isActive)
        XCTAssertTrue(api.rideCreates.isEmpty)

        let started = await coordinator.startRide()
        XCTAssertTrue(started)
        XCTAssertTrue(container.rideRecorder.isActive)
        XCTAssertTrue(container.rideRecorder.isRoaming)
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(api.rideCreates.last?.activity, .run)
        XCTAssertNil(api.rideCreates.last?.routeId)
        container.rideRecorder.discard()
    }

    /// From the wrist it starts at once, on the rider's usual activity when none was asked for.
    func testFromTheWatchARoamStartsWithoutATap() async throws {
        let api = MockAPI()
        let (container, coordinator) = await coordinator(api)
        let start = try XCTUnwrap(WatchStartRequest.roam(activity: nil).quickStart(defaultActivity: .ride))
        let outcome = await coordinator.run(start, autoStart: true)
        XCTAssertEqual(outcome, .started)
        XCTAssertTrue(container.rideRecorder.isRoaming)
        XCTAssertEqual(api.rideCreates.last?.activity, container.session.defaultActivity.isUnknown ? .ride : container.session.defaultActivity)
        XCTAssertEqual(api.rideCreates.last?.bikeId == nil, container.rideRecorder.activity != .ride, "a ride takes the usual bike")
        // A second one while it is under way is refused.
        let again = await coordinator.run(.roam(activity: .ride), autoStart: true)
        XCTAssertEqual(again, .failed("A journey is already under way. End it first."))
        container.rideRecorder.discard()
    }

    /// FEATURE_FLAGS=!ride_anywhere: the phone starts none, from anywhere, and says so plainly.
    func testWithTheFlagOffNoRoamStarts() async throws {
        let api = MockAPI()
        var config = SampleData.sampleConfig
        config.featureFlags["ride_anywhere"] = false
        api.configOverride = config
        let (container, coordinator) = await coordinator(api)
        XCTAssertFalse(container.session.isEnabled(FeatureFlag.rideAnywhere), "the World tab hides its button")
        let fromTheWatch = await coordinator.run(.roam(activity: .ride), autoStart: true)
        XCTAssertEqual(fromTheWatch, .failed("Ride anywhere isn't switched on yet. Plan a ride instead."))
        XCTAssertFalse(container.rideRecorder.isActive)
        let fromALink = await coordinator.run(.roam(activity: .ride), autoStart: false)
        XCTAssertEqual(fromALink, .failed("Ride anywhere isn't switched on yet. Plan a ride instead."))
        XCTAssertTrue(coordinator.isPresented, "the planner, with the reason, to plan one instead")
        XCTAssertTrue(api.rideCreates.isEmpty)
    }

    func testTheIntentAndTheLinkAskForARoam() throws {
        XCTAssertEqual(RideAnywhereIntent().quickStart, .roam(activity: .unknown))
        var walk = RideAnywhereIntent()
        walk.kind = .walk
        XCTAssertEqual(walk.quickStart, .roam(activity: .walk))
        var heard: [QuickStart] = []
        let inbox = DeepLinkInbox()
        inbox.quickStart = { heard.append($0) }
        XCTAssertTrue(inbox.open(try XCTUnwrap(URL(string: "roadsandrunes://quickstart?kind=roam&activity=RIDE"))))
        XCTAssertEqual(heard, [.roam(activity: .ride)])
    }

    func testAJourneyWithNoRouteIsOnTheLockScreen() async throws {
        let container = AppContainer(api: MockAPI(), inMemory: true)
        await container.session.bootstrap()
        let sink = RoamSink()
        let recorder = container.rideRecorder
        recorder.liveActivity = RideActivityController(sink: sink)
        await recorder.startRoam(activity: .run, bikeId: nil)
        XCTAssertEqual(sink.started.count, 1)
        XCTAssertEqual(sink.started.first?.0.activity, "RUN")
        XCTAssertNil(sink.started.first?.0.questTitle)
        ride(recorder, to: SampleData.origin)
        ride(recorder, to: GeoMath.destination(from: SampleData.origin, bearingDegrees: 0, distanceMeters: 300))
        recorder.discard()
        XCTAssertEqual(sink.ended.count, 1)
    }
}

/// The lock screen, in a test.
@MainActor
final class RoamSink: RideActivitySink {
    var started: [(RideActivityAttributes, RideActivityState)] = []
    var updates: [RideActivityState] = []
    var ended: [RideActivityState?] = []
    var isRunning: Bool { !started.isEmpty && ended.isEmpty }

    func start(_ attributes: RideActivityAttributes, state: RideActivityState, staleAfter: TimeInterval) { started.append((attributes, state)) }
    func update(_ state: RideActivityState, staleAfter: TimeInterval) { updates.append(state) }
    func endAll(_ state: RideActivityState?) { ended.append(state) }
}
