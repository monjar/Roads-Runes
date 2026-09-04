import XCTest
@testable import RoadsAndRunesCore

final class PersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoadsAndRunesCoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory = directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testActiveRideStoreRoundTrip() throws {
        let store = FileActiveRideStore(directory: directory)
        XCTAssertNil(try store.load())

        var stats = RideStatistics()
        stats.add(fix: LocationFix(coordinate: SampleData.origin, timestamp: SampleData.referenceDate, altitude: 20, horizontalAccuracy: 5))
        let fix = LocationFix(coordinate: GeoMath.destination(from: SampleData.origin, bearingDegrees: 0, distanceMeters: 50),
                              timestamp: SampleData.referenceDate.addingTimeInterval(10), altitude: 21, horizontalAccuracy: 6, speed: 5, heartRate: 130)
        stats.add(fix: fix)
        let state = ActiveRideState(
            rideId: SampleData.rideId, clientRideId: SampleData.clientRideId, questId: SampleData.questId, routeId: SampleData.routeId,
            bikeId: SampleData.bikeId, navigationState: .active, startedAt: SampleData.referenceDate,
            updatedAt: SampleData.referenceDate.addingTimeInterval(10), stats: stats.snapshot,
            pendingCells: ["89194ad32c3ffff"], visitedCells: ["89194ad32c3ffff", "89194ad32c7ffff"],
            completedObjectiveIDs: [SampleData.objectiveVisitId],
            pendingObjectiveEvents: [ObjectiveEvent(objectiveId: SampleData.objectiveVisitId, occurredAt: SampleData.referenceDate, coordinate: SampleData.origin)],
            lastFix: fix, lastSegmentIndex: 3
        )
        try store.save(state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded, state)
        XCTAssertTrue(loaded.needsRecovery)
        XCTAssertEqual(loaded.stats.distanceMeters, 50, accuracy: 0.5)

        try store.clear()
        XCTAssertNil(try store.load())
        try store.clear() // idempotent
    }

    func testRoutePackageStoreRoundTrip() throws {
        let store = FileRoutePackageStore(directory: directory.appendingPathComponent("routes"))
        XCTAssertEqual(try store.storedRouteIDs(), [])
        XCTAssertNil(try store.load(routeId: SampleData.routeId))

        try store.save(SampleData.sampleRoutePackage)
        let loaded = try XCTUnwrap(try store.load(routeId: SampleData.routeId))
        XCTAssertEqual(loaded, SampleData.sampleRoutePackage)
        XCTAssertEqual(loaded.route.instructions.count, 5)
        XCTAssertEqual(loaded.quest?.id, SampleData.questId)
        XCTAssertEqual(try store.storedRouteIDs(), [SampleData.routeId])

        try store.delete(routeId: SampleData.routeId)
        XCTAssertNil(try store.load(routeId: SampleData.routeId))
        try store.delete(routeId: SampleData.routeId) // idempotent
    }
}
