import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// What a ride says as it goes: the stream the chimes, the voice and the Watch are fed.
@MainActor
final class RideRecorderEventTests: XCTestCase {
    private var api: MockAPI!
    private var container: AppContainer!
    private var recorder: RideRecorder { container.rideRecorder }
    private var clock: TimeInterval = 0

    override func setUp() async throws {
        api = MockAPI()
        container = AppContainer(api: api, inMemory: true)
        clock = 0
    }

    override func tearDown() async throws {
        container.rideRecorder.discard()
        container = nil
        api = nil
    }

    private func ride(to coordinate: Coordinate, after seconds: TimeInterval = 20) {
        clock += seconds
        recorder.handle(fix: LocationFix(coordinate: coordinate, timestamp: SampleData.referenceDate.addingTimeInterval(clock), altitude: 10, horizontalAccuracy: 5, speed: 5))
    }

    private func object(_ kind: WorldObjectKind, _ name: String, at coordinate: Coordinate, coins: Int = 25) -> WorldObject {
        WorldObject(
            id: UUID(), kind: kind, latitude: coordinate.latitude, longitude: coordinate.longitude, name: name, rewardAC: coins,
            expiresAt: Date().addingTimeInterval(86_400),
            monster: kind == .monster ? MonsterInfo(hp: 100, killMethods: [KillMethod(method: .lore, hint: "Leave a note.")]) : nil
        )
    }

    private func isMilestone(_ event: RideEvent, _ which: RideMilestone) -> Bool {
        if case .milestone(let milestone, _) = event { return milestone == which }
        return false
    }

    func testARideSaysWhatIsOnTheWayAndMarksItsMilestonesOnce() async throws {
        let package = try await api.routePackage(id: SampleData.routeId)
        let path = package.route.path
        let chest = object(.chest, "Old chest", at: path[6])
        let elsewhere = object(.chest, "Iron chest", at: GeoMath.destination(from: path[6], bearingDegrees: 0, distanceMeters: 3000))
        api.place([chest, elsewhere], replacing: true)

        await recorder.start(package: package, quest: nil, bikeId: nil)
        XCTAssertEqual(recorder.eventLog.first, .briefing(chests: 1, pieces: 0, monsters: []), "only what lies along the route")
        XCTAssertEqual(recorder.notice, "One chest on this route")
        XCTAssertEqual(Set(recorder.objectsOnMap.map(\.id)), [chest.id, elsewhere.id])

        for point in path { ride(to: point) }
        let log = recorder.eventLog
        let sighted = try XCTUnwrap(log.firstIndex { if case .sighted(let name, .chest, _, _) = $0 { return name == "Old chest" } else { return false } })
        let claimed = try XCTUnwrap(log.firstIndex(of: .claimed(name: "Old chest", kind: .chest, coins: 25, set: nil)))
        XCTAssertLessThan(sighted, claimed, "seen coming before it is opened")
        XCTAssertEqual(log.filter { isMilestone($0, .halfway) }.count, 1)
        XCTAssertEqual(log.filter { isMilestone($0, .arrived) }.count, 1)
        XCTAssertTrue(isMilestone(try XCTUnwrap(log.last { if case .milestone = $0 { return true } else { return false } }), .arrived))
        XCTAssertFalse(recorder.objectsOnMap.contains { $0.id == chest.id }, "an opened chest is off the map")
        // Every cell of a first ride is new ground, and a run of it climbs.
        let runs = log.compactMap { event -> Int? in if case .newGround(let run) = event { return run } else { return nil } }
        XCTAssertFalse(runs.isEmpty)
        XCTAssertEqual(runs, Array(1...runs.count))
    }

    func testAMonsterMetAndLeftBehindIsSaidToHaveGotAway() async throws {
        let package = try await api.routePackage(id: SampleData.routeId)
        let path = package.route.path
        let lair = GeoMath.destination(from: path[3], bearingDegrees: 270, distanceMeters: 60)
        api.place([object(.monster, "Fen Troll", at: lair, coins: 60)], replacing: true)
        await recorder.start(package: package, quest: nil, bikeId: nil)
        for point in path.prefix(4) { ride(to: point) }
        XCTAssertTrue(recorder.eventLog.contains { if case .sighted(let name, .monster, _, _) = $0 { return name == "Fen Troll" } else { return false } })
        XCTAssertFalse(recorder.eventLog.contains(.lost(name: "Fen Troll")))
        // On round the loop, past the far corner: well out of its sight.
        for point in path[4...12] { ride(to: point) }
        XCTAssertEqual(recorder.eventLog.filter { $0 == .lost(name: "Fen Troll") }.count, 1)
    }

    func testAPlaceNotFoundBeforeIsCalledOutOnceInPassing() async throws {
        let package = try await api.routePackage(id: SampleData.routeId)
        api.place([], replacing: true)
        await recorder.start(package: package, quest: nil, bikeId: nil)
        let crown = try XCTUnwrap(SampleData.sampleDiscoveries.first { !$0.discoveredByUser })
        ride(to: package.route.path[0])
        XCTAssertFalse(recorder.eventLog.contains(.newPlace(name: crown.name)))
        ride(to: GeoMath.destination(from: crown.coordinate, bearingDegrees: 90, distanceMeters: 30))
        ride(to: crown.coordinate)
        XCTAssertEqual(recorder.eventLog.filter { $0 == .newPlace(name: crown.name) }.count, 1)
        // A place already found is old news.
        let found = try XCTUnwrap(SampleData.sampleDiscoveries.first { $0.discoveredByUser })
        ride(to: found.coordinate)
        XCTAssertFalse(recorder.eventLog.contains(.newPlace(name: found.name)))
    }

    func testAPieceSaysItsSetAndTheNextCountsOnFromIt() async throws {
        let package = try await api.routePackage(id: SampleData.routeId)
        let path = package.route.path
        var raido = object(.collectable, "Raido (Old Runes)", at: path[4], coins: 10)
        (raido.setId, raido.piece, raido.setName, raido.setSize, raido.setOwned, raido.pieceOwned) = ("RUNES", "Raido", "Old Runes", 6, 2, false)
        var kenaz = object(.collectable, "Kenaz (Old Runes)", at: path[9], coins: 10)
        (kenaz.setId, kenaz.piece, kenaz.setName, kenaz.setSize, kenaz.setOwned, kenaz.pieceOwned) = ("RUNES", "Kenaz", "Old Runes", 6, 2, false)
        api.place([raido, kenaz], replacing: true)
        await recorder.start(package: package, quest: nil, bikeId: nil)
        for point in path.prefix(12) { ride(to: point) }
        XCTAssertTrue(recorder.eventLog.contains(.claimed(name: "Raido", kind: .collectable, coins: 10, set: SetStanding(name: "Old Runes", owned: 3, of: 6))))
        XCTAssertTrue(recorder.eventLog.contains(.claimed(name: "Kenaz", kind: .collectable, coins: 10, set: SetStanding(name: "Old Runes", owned: 4, of: 6))))
    }

    func testLeavingTheRouteAndTheNewOneAreEvents() async throws {
        let package = try await api.routePackage(id: SampleData.routeId)
        api.place([], replacing: true)
        await recorder.start(package: package, quest: nil, bikeId: nil)
        let path = package.route.path
        for point in path.prefix(3) { ride(to: point, after: 3) }
        let astray = GeoMath.destination(from: path[2], bearingDegrees: 270, distanceMeters: 250)
        for _ in 0..<3 { ride(to: astray, after: 3) }
        XCTAssertTrue(recorder.eventLog.contains(.offRoute))
        let deadline = Date().addingTimeInterval(4)
        while recorder.state != .active, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(recorder.eventLog.contains(.rerouted))
    }
}
