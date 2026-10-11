import XCTest
@testable import RoadsAndRunesCore

/// Ride anywhere (0.9.2): a journey with no route, the world refreshed round it as
/// it goes, and the quests it finishes on the way.
final class RideAnywhereTests: XCTestCase {
    // MARK: - Quests where they fit

    func testJourneysEndSaysTheQuestFinishedOnTheWay() throws {
        let decoder = JSONCoding.makeDecoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AdventureSummaryDecodingTests.json.utf8)) as? [String: Any])
        json["quest"] = NSNull()
        json["alsoFinished"] = ["id": "8a1f0b2c-0000-4000-8000-00000000c001", "title": "Ten Miles Out"]
        let summary = try decoder.decode(AdventureSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(summary.alsoFinished, AlsoFinishedQuest(id: "8a1f0b2c-0000-4000-8000-00000000c001", title: "Ten Miles Out"))
        XCTAssertNil(summary.quest)
        XCTAssertEqual(LoreCopy.alsoFinished("Ten Miles Out"), "Also finished: Ten Miles Out")

        // A server from before 0.9.2 sends none.
        let before = try decoder.decode(AdventureSummary.self, from: Data(AdventureSummaryDecodingTests.json.utf8))
        XCTAssertNil(before.alsoFinished)
    }

    // MARK: - The Watch and recovery

    func testARoamsSummaryIsEmptyButForTheWorldAndAnOlderWatchStillReadsIt() throws {
        let start = Coordinate(latitude: 51.49, longitude: -0.04)
        let chest = WorldObject(id: UUID(), kind: .chest, latitude: 51.495, longitude: -0.04, name: "Old chest", rewardAC: 25,
                                expiresAt: Date().addingTimeInterval(86_400))
        let far = WorldObject(id: UUID(), kind: .chest, latitude: 51.53, longitude: -0.04, name: "Far chest", rewardAC: 25,
                              expiresAt: Date().addingTimeInterval(86_400))
        // No route: things within 2 km of the rider.
        let marks = WatchWorldMarks.select(objects: [chest, far], route: [], start: start)
        XCTAssertEqual(marks.map(\.id), [chest.id])

        let summary = WatchRouteSummary.roaming(activity: .run, worldMarks: marks)
        XCTAssertTrue(summary.isRoam)
        XCTAssertEqual(summary.roam, true)
        XCTAssertTrue(summary.instructions.isEmpty && summary.routeCoordinates.isEmpty && summary.objectives.isEmpty)
        let data = try JSONCoding.encode(summary)
        let back = try JSONCoding.makeDecoder().decode(WatchRouteSummary.self, from: data)
        XCTAssertEqual(back, summary)

        // A Watch from before 0.9.2 reads it as a summary with no route (its own no-route face).
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["roam"] as? Bool, true)
        json.removeValue(forKey: "roam")
        let older = try JSONCoding.makeDecoder().decode(WatchRouteSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.roam)
        XCTAssertTrue(older.isRoam, "no turns and no line is no route to follow")
        XCTAssertEqual(older.worldMarks?.map(\.id), [chest.id])
    }

    func testARoamIsRememberedThroughACrash() throws {
        let state = ActiveRideState(clientRideId: UUID(), navigationState: .active, startedAt: Date(), updatedAt: Date(),
                                    stats: RideSnapshot(), visitedCells: ["89194ad1fffffff"], roam: true)
        let back = try JSONCoding.makeDecoder().decode(ActiveRideState.self, from: JSONCoding.encode(state))
        XCTAssertTrue(back.isRoam)
        XCTAssertNil(back.routeId)
        // A snapshot from before 0.9.2 is a planned ride.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encode(state)) as? [String: Any])
        json.removeValue(forKey: "roam")
        let older = try JSONCoding.makeDecoder().decode(ActiveRideState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(older.isRoam)
    }

    // MARK: - Refreshing the world as it goes

    private let start = Coordinate(latitude: 51.49, longitude: -0.04)
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func east(_ meters: Double, of from: Coordinate? = nil) -> Coordinate {
        GeoMath.destination(from: from ?? start, bearingDegrees: 90, distanceMeters: meters)
    }

    private func chest(_ name: String, at place: Coordinate) -> WorldObject {
        WorldObject(id: UUID(), kind: .chest, latitude: place.latitude, longitude: place.longitude, name: name, rewardAC: 25,
                    expiresAt: Date().addingTimeInterval(86_400))
    }

    func testTheWorldIsAskedForAgainEveryKilometreAndAHalfAndNotTooOften() {
        var refresher = RoamRefresher()
        XCTAssertTrue(refresher.shouldRefresh(from: start, at: t0, paused: false), "nothing loaded yet: ask")
        refresher.loaded(from: start, at: t0)
        // One look again 90 s after the start, in case its places had not arrived.
        XCTAssertFalse(refresher.shouldRefresh(from: start, at: t0 + 60, paused: false))
        XCTAssertTrue(refresher.shouldRefresh(from: start, at: t0 + 90, paused: false))
        refresher.began(from: start, at: t0 + 90)
        XCTAssertFalse(refresher.shouldRefresh(from: east(3000), at: t0 + 400, paused: false), "never two at once")
        refresher.succeeded(importing: false)

        // Then 1.5 km on, and never within 90 s of the last ask.
        XCTAssertFalse(refresher.shouldRefresh(from: east(1000), at: t0 + 600, paused: false))
        XCTAssertFalse(refresher.shouldRefresh(from: east(1600), at: t0 + 150, paused: false))
        XCTAssertTrue(refresher.shouldRefresh(from: east(1600), at: t0 + 180, paused: false))
        XCTAssertFalse(refresher.shouldRefresh(from: east(1600), at: t0 + 600, paused: true), "never while paused")
        refresher.began(from: east(1600), at: t0 + 600)
        refresher.succeeded(importing: false)
        XCTAssertEqual(refresher.refreshedFrom, east(1600))
        XCTAssertFalse(refresher.shouldRefresh(from: east(2500), at: t0 + 2000, paused: false), "900 m from the last answer")
        XCTAssertTrue(refresher.shouldRefresh(from: east(3200), at: t0 + 2000, paused: false))
    }

    func testAFailureBacksOffAndPlacesStillComingAreAskedForAgain() {
        var refresher = RoamRefresher()
        refresher.loaded(from: start, at: t0)
        refresher.began(from: start, at: t0 + 90)
        refresher.succeeded(importing: false)
        var now = t0 + 1000
        refresher.began(from: east(2000), at: now)
        refresher.failed()
        XCTAssertEqual(refresher.backoffSeconds, 30)
        XCTAssertFalse(refresher.shouldRefresh(from: east(2000), at: now + 20, paused: false))
        XCTAssertTrue(refresher.shouldRefresh(from: east(2000), at: now + 30, paused: false), "a retry needs no more distance")
        for expected in [60.0, 120, 240, 480, 600, 600] {
            now += 1000
            refresher.began(from: east(2000), at: now)
            refresher.failed()
            XCTAssertEqual(refresher.backoffSeconds, expected)
        }
        XCTAssertEqual(refresher.refreshedFrom, start, "a failure is no answer")

        // The server is still fetching places round here: asked again without moving, three times.
        now += 1000
        refresher.began(from: east(2000), at: now)
        refresher.succeeded(importing: true)
        XCTAssertEqual(refresher.failures, 0)
        for _ in 0..<RoamRefresher.importingRetries {
            now += 90
            XCTAssertTrue(refresher.shouldRefresh(from: east(2000), at: now, paused: false))
            refresher.began(from: east(2000), at: now)
            refresher.succeeded(importing: true)
        }
        XCTAssertFalse(refresher.shouldRefresh(from: east(2000), at: now + 90, paused: false), "then it waits for the next 1.5 km")
    }

    func testANewChestJoinsAndOnlyTheFixesAfterItCanOpenIt() {
        let ahead = chest("Iron chest", at: east(2000))
        let behind = chest("Old chest", at: east(300))
        var tracker = EncounterTracker(objects: [], activity: .ride)
        // The rider passes where the old chest will be, before it is there.
        for (index, meters) in stride(from: 0.0, through: 1800, by: 100).enumerated() {
            _ = tracker.update(position: east(meters), timestamp: t0 + Double(index) * 20, altitude: 10, elevationGainMeters: 0)
        }
        let merge = tracker.merge([ahead, behind, ahead], at: east(1800), now: t0 + 400)
        XCTAssertEqual(Set(merge.added.map(\.id)), [ahead.id, behind.id], "each once")
        XCTAssertEqual(tracker.addedAt[ahead.id], t0 + 400)
        var claimed: [UUID] = []
        for (index, meters) in stride(from: 1800.0, through: 2400, by: 50).enumerated() {
            claimed += tracker.update(position: east(meters), timestamp: t0 + 400 + Double(index) * 10, altitude: 10, elevationGainMeters: 0)
                .claimed.map(\.id)
        }
        XCTAssertEqual(claimed, [ahead.id], "what joined ahead opens; nothing behind is opened by fixes from before it came")
        XCTAssertEqual(tracker.merge([ahead], at: east(2400), now: t0 + 600).added, [], "nothing joins twice, claimed or not")
    }

    func testWhatIsFarBehindIsLetGoButNotWhatWasClaimedOrTheQuarry() {
        let opened = chest("Opened chest", at: start)
        let left = chest("Left chest", at: east(500))
        let quarry = WorldObject(id: UUID(), kind: .monster, latitude: start.latitude, longitude: start.longitude, name: "Fen Troll",
                                 rewardAC: 60, expiresAt: Date().addingTimeInterval(86_400))
        var tracker = EncounterTracker(objects: [opened, left, quarry], activity: .ride)
        _ = tracker.update(position: start, timestamp: t0, altitude: 10, elevationGainMeters: 0)
        XCTAssertTrue(tracker.claimedIDs.contains(opened.id))
        let merge = tracker.merge([], at: east(7000), now: t0 + 1200, keeping: [quarry.id])
        XCTAssertEqual(merge.removed.map(\.id), [left.id])
        XCTAssertEqual(Set(tracker.objects.map(\.id)), [opened.id, quarry.id])
    }

    func testACrashsReplayCannotClaimWithFixesFromBeforeAThingJoined() {
        let later = chest("Iron chest", at: east(300))
        var tracker = EncounterTracker(objects: [], activity: .ride)
        var fixes: [LocationFix] = []
        func go(_ meters: Double, at seconds: Double) {
            let fix = LocationFix(coordinate: east(meters), timestamp: t0 + seconds, altitude: 10, horizontalAccuracy: 5, speed: 5)
            fixes.append(fix)
            _ = tracker.update(position: fix.coordinate, timestamp: fix.timestamp, altitude: 10, elevationGainMeters: 0, accuracy: 5)
        }
        // Past the spot at 60 s; the chest is placed there at 200 s, with the rider 1.2 km on.
        for (index, meters) in stride(from: 0.0, through: 1200, by: 100).enumerated() { go(meters, at: Double(index) * 20) }
        _ = tracker.merge([later], at: east(1200), now: t0 + 260)
        let saved = tracker.gameState(quarryId: nil, fights: nil)
        XCTAssertEqual(saved.addedAt?[later.id], t0 + 260)

        let replayed = EncounterTracker(restoring: saved, activity: .ride, indexing: FakeCellIndexing(), replaying: fixes)
        XCTAssertFalse(replayed.claimedIDs.contains(later.id), "the fixes past the spot came before the chest")
        XCTAssertTrue(replayed.objects.contains { $0.id == later.id }, "it is still there to be had")

        // Saved from before 0.9.2 (no join times), the same fixes would have claimed it.
        var older = saved
        older.addedAt = nil
        XCTAssertTrue(EncounterTracker(restoring: older, activity: .ride, indexing: FakeCellIndexing(), replaying: fixes).claimedIDs.contains(later.id))

        // Coming back past it after it joined, the replay claims it as the ride would have.
        go(600, at: 400)
        go(300, at: 420)
        let back = EncounterTracker(restoring: tracker.gameState(quarryId: nil, fights: nil), activity: .ride, indexing: FakeCellIndexing(), replaying: fixes)
        XCTAssertTrue(back.claimedIDs.contains(later.id))
    }

    func testACreatureThatJoinsIsFoughtOnlyFromThen() {
        let home = start
        func troll() -> WorldObject {
            WorldObject(id: UUID(), kind: .monster, latitude: home.latitude, longitude: home.longitude, name: "Fen Troll", rewardAC: 60,
                        expiresAt: Date().addingTimeInterval(86_400),
                        monster: MonsterInfo(hp: 100, holdMax: 10, holdLeft: 10, wants: ["ROAD", "WORD"], minds: ["CLIMB"]))
        }
        let setup = FightTracker.Setup(constants: CombatConstants(), sheet: CharacterSheet(), activity: .ride, knownCells: [],
                                       groundResolution: 9, indexing: FakeCellIndexing())
        // Armed but with nothing to fight yet: the first creature to join starts it.
        var tracker = EncounterTracker(objects: [], activity: .ride, fights: setup)
        XCTAssertNil(tracker.fights)
        // Right through where it will stand, and 1.5 km on.
        let west = GeoMath.destination(from: home, bearingDegrees: 270, distanceMeters: 600)
        var k = 0
        func ride(_ meters: Double) -> [FightNews] {
            var news: [FightNews] = []
            for _ in 0..<Int(meters / 10) {
                let here = GeoMath.destination(from: west, bearingDegrees: 90, distanceMeters: Double(k) * 10)
                news += tracker.update(position: here, timestamp: t0 + Double(k) * 2, altitude: 10, elevationGainMeters: 0, accuracy: 5).news
                k += 1
            }
            return news
        }
        _ = ride(2100)
        let thing = troll()
        _ = tracker.merge([thing], at: GeoMath.destination(from: west, bearingDegrees: 90, distanceMeters: Double(k) * 10), now: t0 + Double(k) * 2)
        XCTAssertNotNil(tracker.fights, "the fight begins with the first creature")
        XCTAssertNil(tracker.fights?.holdFraction(of: thing.id), "not reached: the road already ridden past it does not count")
        let news = ride(300)
        XCTAssertTrue(news.isEmpty, "riding on, away from it, it is never engaged")
        XCTAssertFalse(tracker.claimedIDs.contains(thing.id))
    }

    /// The same outing past a creature: one there from the start carries the road
    /// ridden on its ground before contact as its opening blow; one that joined just
    /// before contact counts only the road since it came.
    func testTheRoadBeforeACreatureJoinedIsNotCarriedIntoTheFight() throws {
        let home = start
        let setup = FightTracker.Setup(constants: CombatConstants(), sheet: CharacterSheet(), activity: .ride, knownCells: [],
                                       groundResolution: 9, indexing: FakeCellIndexing())
        func troll(at place: Coordinate? = nil) -> WorldObject {
            let place = place ?? home
            return WorldObject(id: UUID(), kind: .monster, latitude: place.latitude, longitude: place.longitude, name: "Fen Troll", rewardAC: 60,
                               expiresAt: Date().addingTimeInterval(86_400),
                               monster: MonsterInfo(hp: 100, holdMax: 5000, holdLeft: 5000, wants: ["ROAD", "WORD"], minds: ["CLIMB"]))
        }
        // One far off from the start, so the fight is under way when the second joins.
        let faraway = troll(at: GeoMath.destination(from: home, bearingDegrees: 0, distanceMeters: 5000))
        let west = GeoMath.destination(from: home, bearingDegrees: 270, distanceMeters: 900)
        func outing(_ tracker: inout EncounterTracker, joining: WorldObject?) {
            for k in 0...150 {
                let here = GeoMath.destination(from: west, bearingDegrees: 90, distanceMeters: Double(k) * 10)
                if let joining, k == 70 { _ = tracker.merge([joining], at: here, now: t0 + Double(k) * 2) }
                _ = tracker.update(position: here, timestamp: t0 + Double(k) * 2, altitude: 10, elevationGainMeters: 0, accuracy: 5)
            }
        }
        let there = troll()
        var fromTheStart = EncounterTracker(objects: [there, faraway], activity: .ride, fights: setup)
        outing(&fromTheStart, joining: nil)
        let joined = troll()
        var later = EncounterTracker(objects: [faraway], activity: .ride, fights: setup)
        outing(&later, joining: joined)
        let leftThere = try XCTUnwrap(fromTheStart.fights?.holdFraction(of: there.id))
        let leftJoined = try XCTUnwrap(later.fights?.holdFraction(of: joined.id))
        XCTAssertLessThan(leftThere, 1)
        XCTAssertLessThan(leftJoined, 1, "it is fought from when it came")
        XCTAssertGreaterThan(leftJoined, leftThere, "the 700 m ridden on its ground before it came are not carried")
    }

    func testTheWorldRoundARoamDecodes() throws {
        let json = #"""
        {"objects": [], "places": [{"id": "8a1f0b2c-0000-4000-8000-00000000d001", "name": "The Crown", "category": "PUB",
          "latitude": 51.495, "longitude": -0.045, "source": "OSM", "discoveredByUser": false}], "importing": true}
        """#
        let around = try JSONCoding.makeDecoder().decode(WorldAround.self, from: Data(json.utf8))
        XCTAssertEqual(around.places.map(\.name), ["The Crown"])
        XCTAssertEqual(around.importing, true)
        let endpoint = Endpoints.worldAround(near: start, rideId: UUID(uuidString: "8a1f0b2c-0000-4000-8000-00000000e001"))
        XCTAssertEqual(endpoint.path, "/world/around")
        XCTAssertEqual(endpoint.query.map(\.name), ["latitude", "longitude", "rideId"])
        XCTAssertEqual(Endpoints.worldAround(near: start, rideId: nil).query.count, 2)
    }

    func testTheButtonSaysTheActivity() {
        XCTAssertEqual(LoreCopy.anywhere(.ride), "Ride anywhere")
        XCTAssertEqual(LoreCopy.anywhere(.run), "Run anywhere")
        XCTAssertEqual(LoreCopy.anywhere(.walk), "Walk anywhere")
        XCTAssertEqual(LoreCopy.anywhere(nil), "Ride anywhere")
        XCTAssertEqual(LoreCopy.stillOut(.ride), "Still out? End ride or keep going.")
        XCTAssertEqual(LoreCopy.stillOut(.walk), "Still out? End walk or keep going.")
        XCTAssertLessThanOrEqual(LoreCopy.anywhere(.walk).split(separator: " ").count, 3)
    }
}
