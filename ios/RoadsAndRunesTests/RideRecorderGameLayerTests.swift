import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// The game layer of a ride (0.7.2): a ride started with no signal takes its world
/// from the last one loaded, and a ride recovered after a crash keeps what it had
/// claimed and fought.
@MainActor
final class RideRecorderGameLayerTests: XCTestCase {
    private var clock: TimeInterval = 0

    private func ride(_ recorder: RideRecorder, to coordinate: Coordinate, after seconds: TimeInterval = 20) {
        clock += seconds
        recorder.handle(fix: LocationFix(coordinate: coordinate, timestamp: SampleData.referenceDate.addingTimeInterval(clock), altitude: 10,
                                         horizontalAccuracy: 5, speed: 5))
    }

    private func chest(_ name: String, at coordinate: Coordinate) -> WorldObject {
        WorldObject(id: UUID(), kind: .chest, latitude: coordinate.latitude, longitude: coordinate.longitude, name: name, rewardAC: 25,
                    expiresAt: Date().addingTimeInterval(86_400))
    }

    private func claims(_ recorder: RideRecorder, of name: String) -> Int {
        recorder.eventLog.filter { if case .claimed(let claimed, _, _, _) = $0 { return claimed == name } else { return false } }.count
    }

    func testARideStartedWithNoSignalTakesItsWorldFromTheLastOneLoaded() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let package = try await api.routePackage(id: SampleData.routeId)
        let path = package.route.path
        let onTheWay = chest("Old chest", at: path[6])
        api.place([onTheWay], replacing: true)
        let recorder = container.rideRecorder

        // With signal: the world round the start is kept beside the route packages.
        await recorder.start(package: package, quest: nil, bikeId: nil)
        XCTAssertEqual(container.worldCache.load()?.objects.map(\.id), [onTheWay.id])
        recorder.discard()

        // No signal at the next start: the same chest is there, and opens on the way.
        api.offline = true
        await recorder.start(package: package, quest: nil, bikeId: nil)
        XCTAssertTrue(recorder.isActive, "a ride starts offline")
        XCTAssertNil(recorder.ride, "the server has not heard of it yet")
        XCTAssertEqual(recorder.objectsOnMap.map(\.id), [onTheWay.id])
        for point in path.prefix(10) { ride(recorder, to: point) }
        XCTAssertEqual(claims(recorder, of: "Old chest"), 1)
        recorder.discard()
    }

    /// What has gone since the world was loaded is not put back on the map.
    func testWhatHasGoneSinceIsLeftOut() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        let package = try await api.routePackage(id: SampleData.routeId)
        let start = try XCTUnwrap(package.route.path.first)
        var gone = chest("Iron chest", at: start)
        gone.expiresAt = Date().addingTimeInterval(-60)
        let far = chest("Far chest", at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 20_000))
        let here = chest("Old chest", at: start)
        try container.worldCache.update { world in world.objects = [gone, far, here] }
        api.offline = true
        await container.rideRecorder.start(package: package, quest: nil, bikeId: nil)
        XCTAssertEqual(container.rideRecorder.objectsOnMap.map(\.name), ["Old chest"])
        container.rideRecorder.discard()
    }

    /// A crash after a chest was passed: on resuming, the chest stays opened, the
    /// creature the ride was planned for is still its quarry, and nothing is claimed twice.
    func testCrashRecoveryKeepsWhatTheRideHadClaimed() async throws {
        let api = MockAPI()
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let package = try await api.routePackage(id: SampleData.routeId)
        let path = package.route.path
        let opened = chest("Old chest", at: path[3])
        let ahead = chest("Iron chest", at: path[14])
        let quarry = SampleData.sampleMonster
        api.place([opened, ahead, quarry], replacing: true)
        let recorder = container.rideRecorder
        await recorder.start(package: package, quest: nil, bikeId: nil, quarryId: quarry.id)
        for point in path.prefix(6) { ride(recorder, to: point) }
        XCTAssertEqual(claims(recorder, of: "Old chest"), 1)
        recorder.pause()  // saves at once

        let saved = try XCTUnwrap(container.activeRideStore.load())
        let game = try XCTUnwrap(saved.game, "the game layer is saved with the ride")
        XCTAssertTrue(game.claimedIDs.contains(opened.id))
        XCTAssertEqual(game.events.map(\.objectId), [opened.id], "the phone's word on the chest, still to be sent")
        XCTAssertEqual(game.quarryId, quarry.id)

        // The app is gone; a fresh one finds the ride and resumes it.
        let fresh = AppContainer(api: MockAPI(), inMemory: true)
        try fresh.activeRideStore.save(saved)
        try fresh.routePackages.save(package)
        fresh.rideRecorder.recoverIfNeeded()
        await fresh.rideRecorder.resumeRecovered()
        let resumed = fresh.rideRecorder
        XCTAssertTrue(resumed.isActive)
        XCTAssertEqual(resumed.quarryId, quarry.id)
        XCTAssertFalse(resumed.objectsOnMap.contains { $0.id == opened.id }, "an opened chest stays opened")
        XCTAssertTrue(resumed.objectsOnMap.contains { $0.id == ahead.id })

        clock = 10_000
        for point in path.prefix(16) { ride(resumed, to: point) }
        XCTAssertEqual(claims(resumed, of: "Old chest"), 0, "not claimed a second time")
        XCTAssertEqual(claims(resumed, of: "Iron chest"), 1, "what is ahead still opens")

        // Saved again, the old claim and the new one are both there to be sent.
        resumed.pause()
        let again = try XCTUnwrap(fresh.activeRideStore.load()?.game)
        XCTAssertEqual(Set(again.events.map(\.objectId)), [opened.id, ahead.id])
        resumed.discard()
    }

    func testTheGearScreenSaysWhatAConsumableDid() {
        let piece = ConsumableStack(id: ConsumableId.mapPiece, name: "Map piece", text: "", count: 1)
        XCTAssertEqual(GearModel.line(for: ConsumableUseResult(revealedTiles: 19, placeName: "The Crown"), used: piece),
                       "Map piece used: 19 tiles revealed round The Crown.")
        let chest = ConsumableStack(id: ConsumableId.sealedChestRare, name: "Sealed chest (Rare)", text: "", count: 1)
        let held = ItemFound(kind: "GEAR", name: "Rowan Twig", rarity: "RARE")
        XCTAssertEqual(GearModel.line(for: ConsumableUseResult(itemFound: held), used: chest), "The sealed chest held Rowan Twig (Rare). It's in your bag.")
        var sold = held
        sold.soldOnTheSpot = true
        sold.soldFor = 120
        XCTAssertEqual(GearModel.line(for: ConsumableUseResult(itemFound: sold), used: chest),
                       "The sealed chest held Rowan Twig (Rare). Your bag was full, so it was sold: +120 coins.")
    }

    /// A brand-new character's first level is not worth a sheet; a player who had
    /// levels before 0.7.2 is told, once, what they gave.
    func testLevelRewardsAreShownOnceAndOnlyForLevelsReached() async throws {
        let container = AppContainer(api: MockAPI(), inMemory: true)
        await container.session.bootstrap()
        await container.session.refreshInventory()
        XCTAssertFalse(container.session.levelRewardsToShow.isEmpty, "level 8 has rewards to show")
        XCTAssertNil(container.session.inventory?.levelRewardsPaid, "kept once, on the sheet")
        container.session.levelRewardsToShow = []
        await container.session.refreshInventory()
        XCTAssertTrue(container.session.levelRewardsToShow.isEmpty, "said once")

        let newcomer = AppContainer(api: MockAPI(hasCharacter: false), inMemory: true)
        await newcomer.session.bootstrap()
        _ = await newcomer.session.createCharacter(name: "Wren", characterClass: .explorer)
        await newcomer.session.refreshInventory()
        XCTAssertTrue(newcomer.session.levelRewardsToShow.isEmpty)
        XCTAssertNotNil(newcomer.session.inventory)
    }
}
