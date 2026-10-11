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
    }

    private func ride(_ recorder: RideRecorder, to coordinate: Coordinate, after seconds: TimeInterval = 20) {
        clock += seconds
        recorder.handle(fix: LocationFix(coordinate: coordinate, timestamp: SampleData.referenceDate.addingTimeInterval(clock), altitude: 10,
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
