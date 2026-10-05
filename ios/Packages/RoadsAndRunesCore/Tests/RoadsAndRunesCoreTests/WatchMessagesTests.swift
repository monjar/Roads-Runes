import XCTest
@testable import RoadsAndRunesCore

/// The Watch messages only grow (0.7.2): a newer message reaches an older Watch
/// as one it can read, and an older phone's message reaches a newer Watch with
/// the new fields simply missing.
final class WatchMessagesTests: XCTestCase {
    private let troll = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000F1")!
    private let chest = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000C1")!

    // MARK: Round trips

    func testTheRouteSummaryCarriesWorldMarksAndStopKinds() throws {
        let marks = [
            WatchWorldMark(id: troll, kind: WatchWorldMark.monster, name: "Fen Troll", latitude: 51.49, longitude: -0.03, icon: "troll",
                           speciesId: "fen-troll", tier: 2, bounty: true, quarry: true),
            WatchWorldMark(id: chest, kind: WatchWorldMark.chest, name: "Old chest", latitude: 51.48, longitude: -0.02, icon: "chest", tier: 1),
        ]
        let stop = WatchStop(id: UUID(), name: "The Crown", latitude: 51.4915, longitude: -0.0365, requested: true, category: "PUB")
        let summary = WatchRouteSummary(questTitle: nil, instructions: [], objectives: [], totalDistanceMeters: 12_000,
                                        stops: [stop], activity: "RIDE", worldMarks: marks)
        let decoded = try WatchMessages.routeSummary(from: WatchMessages.routeSummary(summary))
        XCTAssertEqual(decoded, summary)
        XCTAssertEqual(decoded.worldMarks?.first?.isQuarry, true)
        XCTAssertEqual(decoded.worldMarks?.first?.isBounty, true)
        XCTAssertEqual(decoded.stops.first?.category, "PUB")
    }

    func testTheUpdateCarriesTheFightAndWhatIsGone() throws {
        let fight = WatchFight(speciesId: "fen-troll", name: "Fen Troll", icon: "troll", tenthsLeft: 7, quarry: true, defeated: false)
        let update = WatchNavigationUpdate(state: .active, distanceMeters: 4000, elapsedSeconds: 900, elevationGainMeters: 40,
                                           timestamp: Date(timeIntervalSince1970: 1_000), fight: fight, goneMarkIds: [chest])
        let message = try WatchMessages.navigationUpdate(update)
        XCTAssertEqual(WatchMessages.kind(of: message), .navigationUpdate)
        let decoded = try WatchMessages.navigationUpdate(from: message)
        XCTAssertEqual(decoded.fight, fight)
        XCTAssertEqual(decoded.goneMarkIds, [chest])
    }

    func testTheFightIsInTenthsBetweenNoneAndTen() {
        XCTAssertEqual(WatchFight(speciesId: "x", name: "X", tenthsLeft: 14, quarry: false, defeated: false).tenthsLeft, 10)
        XCTAssertEqual(WatchFight(speciesId: "x", name: "X", tenthsLeft: -2, quarry: false, defeated: true).tenthsLeft, 0)
        XCTAssertEqual(WatchFight.tenths(1), 10)
        XCTAssertEqual(WatchFight.tenths(0.61), 7)
        XCTAssertEqual(WatchFight.tenths(0.02), 1, "a last scrap of health still shows one tick")
        XCTAssertEqual(WatchFight.tenths(0), 0)
        XCTAssertEqual(WatchFight.tenths(-1), 0)
    }

    func testADropCarriesItsMarkAndRarity() throws {
        let drop = WatchObjectiveCompleted.found(name: "Tin Bell", icon: "tinBell", rarity: "COMMON")
        let decoded = try WatchMessages.objectiveCompleted(from: WatchMessages.objectiveCompleted(drop))
        XCTAssertEqual(decoded.outcome, "FOUND")
        XCTAssertEqual(decoded.icon, "tinBell")
        XCTAssertEqual(decoded.rarity, "COMMON")
    }

    func testJourneysEndRoundTripsUnderItsOwnKind() throws {
        let end = WatchJourneyEnd(activity: "RUN", creaturesDefeated: 2, chestsOpened: 1, coins: 120, xp: 340, levelReached: 8,
                                  finds: [WatchFind(name: "Tin Bell", icon: "tinBell", rarity: "COMMON")],
                                  endedAt: Date(timeIntervalSince1970: 2_000))
        let message = try WatchMessages.journeyEnd(end)
        XCTAssertEqual(WatchMessages.kind(of: message), .journeyEnd)
        XCTAssertEqual(try WatchMessages.journeyEnd(from: message), end)
        XCTAssertThrowsError(try WatchMessages.navigationUpdate(from: message)) { error in
            XCTAssertEqual(error as? WatchMessageError, .kindMismatch(expected: .navigationUpdate, actual: .journeyEnd))
        }
    }

    // MARK: An older phone

    func testAnOlderPhonesMessagesLackTheNewFields() throws {
        let summary = try JSONCoding.decode(WatchRouteSummary.self, json: """
        {"questTitle": null, "instructions": [], "objectives": [], "totalDistanceMeters": 5000, "routeCoordinates": [],
         "stops": [{"id": "\(UUID().uuidString)", "name": "The Crown", "latitude": 51.49, "longitude": -0.03, "requested": false}],
         "activity": "RIDE"}
        """)
        XCTAssertNil(summary.worldMarks)
        XCTAssertNil(summary.stops.first?.category)

        let update = try JSONCoding.decode(WatchNavigationUpdate.self, json: """
        {"state": "ACTIVE", "distanceMeters": 100, "elapsedSeconds": 30, "elevationGainMeters": 0,
         "timestamp": "2026-10-04T10:00:00Z", "encounterLine": "Fen Troll · 120 m", "courseDegrees": 90}
        """)
        XCTAssertNil(update.fight)
        XCTAssertNil(update.goneMarkIds)
        XCTAssertEqual(update.encounterLine, "Fen Troll · 120 m")

        let claim = try JSONCoding.decode(WatchObjectiveCompleted.self, json: """
        {"title": "Fen Troll", "coins": 60, "outcome": "GONE"}
        """)
        XCTAssertNil(claim.icon)
        XCTAssertNil(claim.rarity)
    }

    // MARK: An older Watch

    /// The 0.7.1 shapes, as a Watch from before this release decodes them.
    private struct OldStop: Decodable {
        var id: UUID
        var name: String
        var latitude: Double
        var longitude: Double
        var requested: Bool
    }

    private struct OldRouteSummary: Decodable {
        var questTitle: String?
        var instructions: [Instruction]
        var objectives: [WatchObjective]
        var totalDistanceMeters: Double
        var routeCoordinates: [[Double]]
        var stops: [OldStop]
        var activity: String?
    }

    private struct OldUpdate: Decodable {
        var state: NavigationState
        var distanceMeters: Double
        var elapsedSeconds: Double
        var elevationGainMeters: Double
        var timestamp: Date
        var encounterLine: String?
        var courseDegrees: Double?
    }

    private struct OldObjectiveCompleted: Decodable {
        var title: String
        var xp: Int?
        var coins: Int?
        var detail: String?
        var outcome: String?
    }

    /// Before 0.7.2: no `journeyEnd`.
    private enum OldKind: String {
        case routeSummary, navigationUpdate, objectiveCompleted, command, heartRate, encounterBeat
    }

    func testAnOlderWatchReadsTheNewMessagesAndDropsWhatItDoesNotKnow() throws {
        let summary = WatchRouteSummary(
            questTitle: "The Forgotten Railway", instructions: [], objectives: [], totalDistanceMeters: 30_000,
            routeCoordinates: [[-0.03, 51.49], [-0.02, 51.50]],
            stops: [WatchStop(id: UUID(), name: "The Crown", latitude: 51.49, longitude: -0.03, requested: true, category: "PUB")],
            activity: "WALK",
            worldMarks: [WatchWorldMark(id: troll, kind: WatchWorldMark.monster, name: "Fen Troll", latitude: 51.49, longitude: -0.03)]
        )
        let oldSummary = try JSONCoding.decode(OldRouteSummary.self, from: JSONCoding.encode(summary))
        XCTAssertEqual(oldSummary.questTitle, "The Forgotten Railway")
        XCTAssertEqual(oldSummary.stops.first?.name, "The Crown")
        XCTAssertEqual(oldSummary.activity, "WALK")

        let update = WatchNavigationUpdate(
            state: .paused, distanceMeters: 2000, elapsedSeconds: 600, elevationGainMeters: 12, timestamp: Date(timeIntervalSince1970: 3_000),
            encounterLine: "Fen Troll · 80 m", courseDegrees: 180,
            fight: WatchFight(speciesId: "fen-troll", name: "Fen Troll", tenthsLeft: 3, quarry: false, defeated: false), goneMarkIds: [chest]
        )
        let oldUpdate = try JSONCoding.decode(OldUpdate.self, from: JSONCoding.encode(update))
        XCTAssertEqual(oldUpdate.state, .paused)
        XCTAssertEqual(oldUpdate.encounterLine, "Fen Troll · 80 m")
        XCTAssertEqual(oldUpdate.courseDegrees, 180)

        let drop = WatchObjectiveCompleted.found(name: "Hagstone", icon: "hagstone", rarity: "COMMON", detail: "From Fen Troll")
        let oldDrop = try JSONCoding.decode(OldObjectiveCompleted.self, from: JSONCoding.encode(drop))
        XCTAssertEqual(oldDrop.title, "Hagstone")
        XCTAssertEqual(oldDrop.outcome, "FOUND")

        // An older Watch cannot name the new kind, so it ignores the message.
        let end = try WatchMessages.journeyEnd(WatchJourneyEnd(coins: 10))
        let raw = try XCTUnwrap(end[WatchMessageKind.kindKey] as? String)
        XCTAssertNil(OldKind(rawValue: raw))
    }

    // MARK: Journey's end from the summary

    func testJourneysEndIsBuiltFromTheProcessedSummary() throws {
        var summary = SampleData.sampleAdventureSummary
        summary.ride.activity = .run
        summary.worldObjects = WorldObjectOutcome(claimed: [
            ClaimedObject(id: troll, kind: .monster, name: "Fen Troll", rewardAC: 60),
            ClaimedObject(id: UUID(), kind: .monster, name: "Bog Wraith", rewardAC: 40),
            ClaimedObject(id: chest, kind: .chest, name: "Old chest", rewardAC: 25),
            ClaimedObject(id: UUID(), kind: .collectable, name: "Raido (Old Runes)", rewardAC: 10),
        ])
        summary.levelUps = [LevelUp(kind: .classLevel, from: 2, to: 3), LevelUp(kind: .overall, from: 7, to: 8)]
        summary.runesFound = [RuneFound(rune: "raido", new: true, rank: 1, shards: 0), RuneFound(rune: "kenaz", new: false, rank: 2, shards: 3)]
        summary.itemsFound = [
            ItemFound(kind: "GEAR", itemId: "tin-bell", name: "Tin Bell", icon: "tinBell", rarity: "COMMON", source: "MONSTER"),
            ItemFound(kind: "GEAR", itemId: "hagstone", name: "Hagstone", icon: "hagstone", rarity: "COMMON", source: "CHEST",
                      soldOnTheSpot: true, soldFor: 40),
        ]

        let end = WatchJourneyEnd(summary: summary) { $0 == .pub ? "tavern" : nil }
        XCTAssertEqual(end.activity, "RUN")
        XCTAssertEqual(end.creaturesDefeated, 2)
        XCTAssertEqual(end.chestsOpened, 1)
        XCTAssertEqual(end.coins, 58)
        XCTAssertEqual(end.xp, 420)
        XCTAssertEqual(end.levelReached, 8, "the overall level, not a class level")
        XCTAssertEqual(end.endedAt, summary.ride.endedAt)
        XCTAssertEqual(end.finds.map(\.name), ["Tin Bell", "Hagstone (sold)", "New rune: Raido", "Kenaz rune stone", "The Crown", "Greenwich Foot Tunnel"])
        XCTAssertEqual(end.finds.map(\.icon), ["tinBell", "hagstone", "runeStone", "runeStone", "tavern", nil])
        XCTAssertEqual(end.finds.first?.rarity, "COMMON")

        var quiet = SampleData.sampleAdventureSummary
        quiet.levelUps = []
        quiet.discoveries = []
        quiet.acAwarded = nil
        quiet.itemsFound = nil
        quiet.runesFound = nil
        let plain = WatchJourneyEnd(summary: quiet)
        XCTAssertNil(plain.levelReached)
        XCTAssertEqual(plain.coins, 0, "an older server without coins says none")
        XCTAssertEqual(plain.creaturesDefeated, 0)
        XCTAssertTrue(plain.finds.isEmpty)
    }

    // MARK: Which world marks go

    private func thing(_ kind: WorldObjectKind, at coordinate: Coordinate, id: UUID = UUID(), bounty: Bool = false,
                       status: WorldObjectStatus = .spawned) -> WorldObject {
        WorldObject(id: id, kind: kind, status: status, tier: 1, latitude: coordinate.latitude, longitude: coordinate.longitude,
                    name: "\(kind.rawValue) \(id.uuidString.prefix(4))", bounty: bounty, rewardAC: 10, expiresAt: Date(timeIntervalSince1970: 9_999_999))
    }

    private let start = Coordinate(latitude: 51.5, longitude: -0.1)

    /// A point `meters` north of the start: the test route runs east from it.
    private func north(_ meters: Double, east: Double = 500) -> Coordinate {
        let across = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: east)
        return GeoMath.destination(from: across, bearingDegrees: 0, distanceMeters: meters)
    }

    private var route: [Coordinate] {
        (0...10).map { GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: Double($0) * 300) }
    }

    func testThingsNearTheRouteGoAndThingsFarOrTakenDoNot() {
        let near = thing(.chest, at: north(1_400))
        let far = thing(.monster, at: north(1_700))
        let taken = thing(.chest, at: north(100), status: .claimed)
        let odd = thing(.unknown, at: north(100))
        let marks = WatchWorldMarks.select(objects: [near, far, taken, odd], route: route, start: start) { $0.kind == .chest ? "chest" : nil }
        XCTAssertEqual(marks.map(\.id), [near.id])
        XCTAssertEqual(marks.first?.icon, "chest")
        XCTAssertEqual(marks.first?.kind, "CHEST")
    }

    func testWithNoRouteThingsNearTheStartGo() {
        let near = thing(.collectable, at: north(1_900, east: 0))
        let far = thing(.collectable, at: north(2_100, east: 0))
        let marks = WatchWorldMarks.select(objects: [near, far], route: [], start: start)
        XCTAssertEqual(marks.map(\.id), [near.id])
        XCTAssertTrue(WatchWorldMarks.select(objects: [near], route: [], start: nil).isEmpty, "nowhere to measure from")
    }

    func testAtMostThirtyGoTheQuarryAndBountiesFirstThenTheNearestThenTheObjectives() throws {
        var objects = (0..<40).map { thing(.chest, at: north(Double(40 - $0) * 30)) }
        let bounty = thing(.monster, at: north(1_300), bounty: true)
        let quarry = thing(.monster, at: north(5_000))   // far off, but it is what the journey is for
        objects += [bounty, quarry]
        let objective = Objective(id: UUID(), objectiveType: .visitLocation, title: "Reach Old Station", latitude: 51.51, longitude: -0.09,
                                  required: true, order: 1, progress: ObjectiveProgress(current: 0, target: 1))
        let marks = WatchWorldMarks.select(objects: objects, route: route, start: start, objectives: [objective], quarryId: quarry.id)
        XCTAssertEqual(marks.count, WatchWorldMarks.limit + 1)
        XCTAssertEqual(marks[0].id, quarry.id)
        XCTAssertEqual(marks[0].quarry, true)
        XCTAssertEqual(marks[1].id, bounty.id)
        XCTAssertEqual(marks[1].bounty, true)
        XCTAssertNil(marks[2].quarry)
        // The nearest of the chests: the last ones made, 30 m from the route upward.
        XCTAssertEqual(marks[2].id, objects[39].id)
        XCTAssertFalse(marks.contains { $0.id == objects[0].id }, "the farthest chest did not make the cut")
        let flag = try XCTUnwrap(marks.last)
        XCTAssertEqual(flag.id, objective.id)
        XCTAssertEqual(flag.kind, WatchWorldMark.objective)
        XCTAssertEqual(flag.name, "Reach Old Station")
        XCTAssertEqual(flag.icon, "flag")
    }

    func testAnObjectiveWithNoPlaceHasNoMark() {
        let distance = Objective(id: UUID(), objectiveType: .completeDistance, title: "Ride 20 km", targetMeters: 20_000,
                                 required: true, order: 1, progress: ObjectiveProgress(current: 0, target: 20_000))
        XCTAssertTrue(WatchWorldMarks.select(objects: [], route: route, start: start, objectives: [distance]).isEmpty)
    }

    // MARK: Which fight shows

    private func creature(_ name: String, at coordinate: Coordinate, holdLeft: Int = 400) -> WorldObject {
        var object = thing(.monster, at: coordinate)
        object.name = name
        object.monster = MonsterInfo(hp: 400, speciesId: name.lowercased().replacingOccurrences(of: " ", with: "-"),
                                     holdMax: 400, holdLeft: holdLeft, wants: ["ROAD"])
        return object
    }

    func testTheQuarryIsTheFightFromTheStart() throws {
        let quarry = creature("Fen Troll", at: north(3_000), holdLeft: 260)
        let other = creature("Bog Wraith", at: north(50))
        let fight = try XCTUnwrap(WatchFight.pick(
            objects: [quarry, other], quarryId: quarry.id, from: start, isFought: { _ in true },
            healthLeft: { $0 == other.id ? 0.5 : nil }, isDefeated: { _ in false }, icon: { _ in "troll" }
        ))
        XCTAssertEqual(fight.name, "Fen Troll")
        XCTAssertEqual(fight.speciesId, "fen-troll")
        XCTAssertEqual(fight.icon, "troll")
        XCTAssertTrue(fight.quarry)
        XCTAssertFalse(fight.defeated)
        XCTAssertEqual(fight.tenthsLeft, 7, "260 of 400 health before the journey reaches it")
    }

    func testWithoutAQuarryTheNearestCreatureBeingFoughtShows() throws {
        let near = creature("Bog Wraith", at: north(100))
        let far = creature("Grey Stag", at: north(900))
        let untouched = creature("Mire Hag", at: north(10))
        let health: [UUID: Double] = [near.id: 0.33, far.id: 0.9]
        let fight = try XCTUnwrap(WatchFight.pick(
            objects: [far, near, untouched], quarryId: nil, from: start, isFought: { _ in true },
            healthLeft: { health[$0] }, isDefeated: { _ in false }
        ))
        XCTAssertEqual(fight.name, "Bog Wraith")
        XCTAssertEqual(fight.tenthsLeft, 4)
        XCTAssertFalse(fight.quarry)
        XCTAssertNil(WatchFight.pick(objects: [untouched], quarryId: nil, from: start, isFought: { _ in true },
                                     healthLeft: { _ in nil }, isDefeated: { _ in false }), "nothing reached, no fight")
        XCTAssertNil(WatchFight.pick(objects: [near], quarryId: nil, from: start, isFought: { _ in false },
                                     healthLeft: { _ in 0.5 }, isDefeated: { _ in false }), "not fought by effort")
    }

    func testADefeatedQuarryGivesWayToAnotherFightOrShowsDefeated() throws {
        let quarry = creature("Fen Troll", at: north(300))
        let other = creature("Bog Wraith", at: north(600))
        let next = try XCTUnwrap(WatchFight.pick(
            objects: [quarry, other], quarryId: quarry.id, from: start, isFought: { _ in true },
            healthLeft: { $0 == quarry.id ? 0 : 0.8 }, isDefeated: { $0 == quarry.id }
        ))
        XCTAssertEqual(next.name, "Bog Wraith")
        let done = try XCTUnwrap(WatchFight.pick(
            objects: [quarry, other], quarryId: quarry.id, from: start, isFought: { _ in true },
            healthLeft: { $0 == quarry.id ? 0 : nil }, isDefeated: { $0 == quarry.id }
        ))
        XCTAssertEqual(done.name, "Fen Troll")
        XCTAssertTrue(done.defeated)
        XCTAssertTrue(done.quarry)
        XCTAssertEqual(done.tenthsLeft, 0)
    }

    func testAPhoneThatIsNotFollowingFightsSendsNone() {
        let tracker = EncounterTracker(objects: [creature("Fen Troll", at: north(100))], activity: .ride)
        XCTAssertNil(tracker.watchFight(quarryId: nil, from: start))
    }
}
