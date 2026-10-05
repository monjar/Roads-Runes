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
        XCTAssertEqual(loaded.rideId, state.rideId)
        XCTAssertEqual(loaded.clientRideId, state.clientRideId)
        XCTAssertEqual(loaded.questId, state.questId)
        XCTAssertEqual(loaded.navigationState, .active)
        XCTAssertEqual(loaded.startedAt, state.startedAt)
        XCTAssertEqual(loaded.pendingCells, state.pendingCells)
        XCTAssertEqual(loaded.visitedCells, state.visitedCells)
        XCTAssertEqual(loaded.completedObjectiveIDs, state.completedObjectiveIDs)
        XCTAssertEqual(loaded.pendingObjectiveEvents.count, 1)
        XCTAssertEqual(loaded.lastFix?.heartRate, 130)
        XCTAssertEqual(loaded.lastFix?.coordinate.latitude ?? 0, fix.coordinate.latitude, accuracy: 1e-9)
        XCTAssertEqual(loaded.lastSegmentIndex, 3)
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
        XCTAssertEqual(loaded.route.id, SampleData.routeId)
        XCTAssertEqual(loaded.route.label, "Adventure")
        XCTAssertEqual(loaded.route.coordinates.count, SampleData.sampleRoute.coordinates.count)
        XCTAssertEqual(loaded.route.encodedPolyline, SampleData.sampleRoute.encodedPolyline)
        XCTAssertEqual(loaded.route.instructions.map { $0.text }, SampleData.sampleRoute.instructions.map { $0.text })
        XCTAssertEqual(loaded.route.instructions.map { $0.coordinateIndex }, [0, 5, 10, 15, 20])
        XCTAssertEqual(loaded.route.distanceMeters, SampleData.sampleRoute.distanceMeters, accuracy: 1e-6)
        XCTAssertEqual(loaded.generatedAt, SampleData.referenceDate)
        XCTAssertEqual(loaded.pois.count, 1)
        XCTAssertEqual(loaded.route.instructions.count, 5)
        XCTAssertEqual(loaded.quest?.id, SampleData.questId)
        XCTAssertEqual(try store.storedRouteIDs(), [SampleData.routeId])

        try store.delete(routeId: SampleData.routeId)
        XCTAssertNil(try store.load(routeId: SampleData.routeId))
        try store.delete(routeId: SampleData.routeId) // idempotent
    }

    // MARK: 0.7.2: the game layer and the last world

    func testTheGameLayerIsSavedWithTheRideAndAnOlderSnapshotStillReads() throws {
        let store = FileActiveRideStore(directory: directory)
        let setup = FightSetupState(constants: CombatConstants(), sheet: CharacterSheet(), knownCells: ["a", "b"], groundResolution: 9,
                                    readBounds: BoundingBox(minLat: 51.4, minLon: -0.1, maxLat: 51.6, maxLon: 0.1))
        let event = EncounterEvent(objectId: SampleData.sampleChest.id, method: "PASS", occurredAt: SampleData.referenceDate)
        let game = RideGameState(objects: SampleData.sampleObjects, claimedIDs: [SampleData.sampleChest.id], events: [event],
                                 quarryId: SampleData.sampleMonster.id, sightMeters: 500, fights: setup)
        let state = ActiveRideState(clientRideId: SampleData.clientRideId, navigationState: .active, startedAt: SampleData.referenceDate,
                                    updatedAt: SampleData.referenceDate, stats: RideSnapshot(), game: game)
        try store.save(state)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.game, game)
        XCTAssertEqual(loaded.game?.fights?.setup(activity: .ride, indexing: FakeCellIndexing()).knownCells, ["a", "b"])

        // A snapshot written by 0.7.1 has no game layer and still offers recovery.
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        raw.removeValue(forKey: "game")
        try JSONSerialization.data(withJSONObject: raw).write(to: store.fileURL)
        let older = try XCTUnwrap(try store.load())
        XCTAssertNil(older.game)
        XCTAssertTrue(older.needsRecovery)
    }

    func testTheLastWorldIsKeptBesideTheRoutesAPartAtATime() throws {
        let routes = directory.appendingPathComponent("routes")
        let cache = FileWorldCacheStore(directory: routes)
        XCTAssertNil(cache.load())
        var gone = SampleData.sampleChest
        gone.id = UUID()
        gone.expiresAt = SampleData.referenceDate.addingTimeInterval(-60)
        try cache.update { world in
            world.center = SampleData.origin
            world.radiusMeters = 8000
            world.objects = SampleData.sampleObjects + [gone]
        }
        let box = BoundingBox(minLat: 51.45, minLon: -0.1, maxLat: 51.55, maxLon: 0.0)
        try cache.update { world in
            world.exploredCells = ["89194ad32c3ffff"]
            world.h3Resolution = 9
            world.cellsBounds = box
            world.combat = CombatConstants()
            world.sheet = CharacterSheet(version: 4)
        }
        let world = try XCTUnwrap(cache.load())
        XCTAssertEqual(world.objects.count, 4, "the second save kept the first's objects")
        XCTAssertEqual(world.sheet?.version, 4)
        let near = world.objects(near: SampleData.origin, radiusMeters: 8000, now: SampleData.referenceDate)
        XCTAssertEqual(Set(near.map(\.id)), Set(SampleData.sampleObjects.map(\.id)), "what has gone stays gone")
        XCTAssertTrue(world.objects(near: Coordinate(latitude: 10, longitude: 10), radiusMeters: 8000, now: SampleData.referenceDate).isEmpty)

        let start = BoundingBox(minLat: 51.48, minLon: -0.05, maxLat: 51.60, maxLon: 0.05)
        let cells = try XCTUnwrap(world.cells(resolution: 9, covering: start))
        XCTAssertEqual(cells.cells, ["89194ad32c3ffff"])
        XCTAssertEqual(cells.bounds, BoundingBox(minLat: 51.48, minLon: -0.05, maxLat: 51.55, maxLon: 0.0), "trusted only where both meet")
        XCTAssertNil(world.cells(resolution: 10, covering: start), "another resolution is no use")
        XCTAssertNil(world.cells(resolution: 9, covering: BoundingBox(minLat: 10, minLon: 10, maxLat: 11, maxLon: 11)))

        // It sits beside the route packages without being taken for one.
        try FileRoutePackageStore(directory: routes).save(SampleData.sampleRoutePackage)
        XCTAssertEqual(try FileRoutePackageStore(directory: routes).storedRouteIDs(), [SampleData.routeId])
        try cache.clear()
        XCTAssertNil(cache.load())
    }
}
