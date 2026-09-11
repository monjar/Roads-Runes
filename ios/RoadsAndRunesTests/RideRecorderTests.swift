import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// Exercises the ride engine against MockAPI with an in-memory store.
/// Location/HealthKit/Watch are real services but produce no events in tests.
@MainActor
final class RideRecorderTests: XCTestCase {
    private func makeContainer() -> AppContainer {
        AppContainer(api: MockAPI(), inMemory: true)
    }

    private func fix(_ coordinate: Coordinate, at seconds: TimeInterval, speed: Double = 5) -> LocationFix {
        LocationFix(coordinate: coordinate, timestamp: SampleData.referenceDate.addingTimeInterval(seconds), altitude: 10, horizontalAccuracy: 5, speed: speed)
    }

    func testStartRideFixesAndFinishProducesCompletion() async throws {
        let container = makeContainer()
        await container.session.bootstrap()
        let api = container.api
        let package = try await api.routePackage(id: SampleData.routeId)
        let quest = package.quest ?? SampleData.sampleQuest
        let recorder = container.rideRecorder

        await recorder.start(package: package, quest: quest, bikeId: SampleData.bikeId)
        XCTAssertTrue(recorder.isActive)
        XCTAssertEqual(recorder.state, .active)
        XCTAssertNotNil(recorder.ride)

        // Ride along the route: distance accumulates, progress advances.
        let path = package.route.path
        for (index, coordinate) in path.prefix(40).enumerated() {
            recorder.handle(fix: fix(coordinate, at: Double(index) * 10))
        }
        XCTAssertGreaterThan(recorder.stats.distanceMeters, 100)
        XCTAssertNotNil(recorder.progress)
        XCTAssertFalse(recorder.progress?.isOffRoute ?? true)

        // Visiting a location objective twice completes it client-side (provisional).
        // Split out with an explicit type: the one-line `||` of implicit members timed out the type checker.
        let locationObjective = quest.objectives.first { (objective: Objective) -> Bool in
            switch objective.objectiveType {
            case .visitLocation, .visitPOI: return true
            default: return false
            }
        }
        if let objective = locationObjective, let target = objective.coordinate {
            recorder.handle(fix: fix(target, at: 1000))
            recorder.handle(fix: fix(target, at: 1010))
            XCTAssertTrue(recorder.completedObjectiveIDs.contains(objective.id))
        }

        await recorder.finish()
        XCTAssertFalse(recorder.isActive)
        XCTAssertEqual(recorder.state, .completed)
        XCTAssertNil(try container.activeRideStore.load())
    }

    func testPauseResumeTransitions() async throws {
        let container = makeContainer()
        await container.session.bootstrap()
        let package = try await container.api.routePackage(id: SampleData.routeId)
        let recorder = container.rideRecorder
        await recorder.start(package: package, quest: package.quest, bikeId: nil)
        recorder.pause()
        XCTAssertEqual(recorder.state, .paused)
        recorder.handle(fix: fix(package.route.path[0], at: 5))
        XCTAssertEqual(recorder.stats.distanceMeters, 0, "fixes are ignored while paused")
        recorder.resume()
        XCTAssertEqual(recorder.state, .active)
        recorder.discard()
        XCTAssertEqual(recorder.state, .cancelled)
        XCTAssertFalse(recorder.isActive)
    }

    func testRecoveryStateRoundTrip() async throws {
        let container = makeContainer()
        await container.session.bootstrap()
        let package = try await container.api.routePackage(id: SampleData.routeId)
        let recorder = container.rideRecorder
        await recorder.start(package: package, quest: package.quest, bikeId: nil)
        for (index, coordinate) in package.route.path.prefix(10).enumerated() {
            recorder.handle(fix: fix(coordinate, at: Double(index) * 10))
        }
        // Simulate a crash: the persisted state exists and needs recovery.
        let saved = try XCTUnwrap(container.activeRideStore.load())
        XCTAssertTrue(saved.needsRecovery)
        XCTAssertEqual(saved.clientRideId, recorder.clientRideId)

        let fresh = AppContainer(api: MockAPI(), inMemory: true)
        try fresh.activeRideStore.save(saved)
        try fresh.routePackages.save(package)
        fresh.rideRecorder.recoverIfNeeded()
        XCTAssertEqual(fresh.rideRecorder.recoverableRide?.clientRideId, saved.clientRideId)
        await fresh.rideRecorder.resumeRecovered()
        XCTAssertTrue(fresh.rideRecorder.isActive)
        XCTAssertEqual(fresh.rideRecorder.state, .active)
        XCTAssertEqual(fresh.rideRecorder.clientRideId, saved.clientRideId)
        fresh.rideRecorder.discard()
    }
}
