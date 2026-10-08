import XCTest
@testable import RoadsAndRunesCore

/// Legends on the wrist (0.8.0): the fight in phases, "Phase broken!", the legend
/// and the lair on the Watch map, and Journey's end. Every new field is optional
/// both ways, so a Watch or a phone a release behind still reads the other.
final class WatchLegendTests: XCTestCase {
    private let dragonId = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000D1")!
    private let start = Coordinate(latitude: 51.5, longitude: -0.1)

    private func legend(phase: Int = 2, left: Int = 300, at coordinate: Coordinate? = nil) -> Legend {
        let place = coordinate ?? GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 3_000)
        let phases = (1...3).map { n in
            LegendPhase(n: n, weakTo: n == 3 ? ["RUNE"] : ["GROUND"], resists: ["WORD"], healthMax: 500,
                        healthLeft: n < phase ? 0 : (n == phase ? left : 500), broken: n < phase)
        }
        return Legend(id: dragonId, speciesId: "fog-dragon", name: "The Fog Dragon", icon: "fogDragon",
                      latitude: place.latitude, longitude: place.longitude, phase: phase, phases: phases)
    }

    private func creature(_ name: String, at coordinate: Coordinate, bounty: Bool = false) -> WorldObject {
        WorldObject(id: UUID(), kind: .monster, latitude: coordinate.latitude, longitude: coordinate.longitude, name: name,
                    bounty: bounty, rewardAC: 10, expiresAt: Date(timeIntervalSince1970: 9_999_999),
                    monster: MonsterInfo(hp: 400, speciesId: "fen-troll", holdMax: 400, holdLeft: 400, wants: ["ROAD"]))
    }

    // MARK: The fight in phases

    func testALegendsFightCarriesItsPhasesAndAnOlderOneHasNone() throws {
        let fight = WatchFight(speciesId: "fog-dragon", name: "The Fog Dragon", icon: "fogDragon", tenthsLeft: 6, quarry: true,
                               defeated: false, phase: 2, phases: 3)
        XCTAssertTrue(fight.isLegend)
        XCTAssertEqual(fight.phasesBroken, 1)
        let update = WatchNavigationUpdate(state: .active, distanceMeters: 4000, elapsedSeconds: 900, elevationGainMeters: 40,
                                           timestamp: Date(timeIntervalSince1970: 1_000), fight: fight)
        let decoded = try WatchMessages.navigationUpdate(from: WatchMessages.navigationUpdate(update))
        XCTAssertEqual(decoded.fight, fight)
        XCTAssertEqual(decoded.fight?.phase, 2)
        XCTAssertEqual(decoded.fight?.phases, 3)

        // An older phone's fight: a creature.
        let old = try JSONCoding.decode(WatchFight.self, json: """
        {"speciesId": "fen-troll", "name": "Fen Troll", "tenthsLeft": 4, "quarry": false, "defeated": false}
        """)
        XCTAssertFalse(old.isLegend)
        XCTAssertNil(old.phase)
        XCTAssertEqual(old.phasesBroken, 0)

        // An older Watch reads a legend as a creature with this phase's health.
        struct OldFight: Decodable {
            var speciesId: String
            var name: String
            var tenthsLeft: Int
            var quarry: Bool
            var defeated: Bool
        }
        let older = try JSONCoding.decode(OldFight.self, from: JSONCoding.encode(fight))
        XCTAssertEqual(older.name, "The Fog Dragon")
        XCTAssertEqual(older.tenthsLeft, 6)
    }

    func testPhasesAreKeptInRangeAndADefeatBreaksThemAll() {
        let high = WatchFight(speciesId: "x", name: "X", tenthsLeft: 5, quarry: false, defeated: false, phase: 7, phases: 3)
        XCTAssertEqual(high.phase, 3)
        XCTAssertEqual(high.phasesBroken, 2)
        let low = WatchFight(speciesId: "x", name: "X", tenthsLeft: 5, quarry: false, defeated: false, phase: 0, phases: 3)
        XCTAssertEqual(low.phase, 1)
        XCTAssertEqual(low.phasesBroken, 0)
        let down = WatchFight(speciesId: "x", name: "X", tenthsLeft: 0, quarry: true, defeated: true, phase: 3, phases: 3)
        XCTAssertEqual(down.phasesBroken, 3)
        XCTAssertNil(WatchFight(speciesId: "x", name: "X", tenthsLeft: 5, quarry: false, defeated: false, phase: 2).phase,
                     "a phase with no count is a creature's, and means nothing")
    }

    func testTheLegendIsTheFightWhileItIsTheQuarry() throws {
        let foe = try XCTUnwrap(legend(phase: 2, left: 300).foe)
        let near = creature("Fen Troll", at: start)
        let fight = try XCTUnwrap(WatchFight.pick(
            objects: [near, foe], quarryId: dragonId, from: start, isFought: { _ in true },
            healthLeft: { $0 == near.id ? 0.5 : nil }, isDefeated: { _ in false }, icon: { $0.monster?.sigil?.icon }
        ))
        XCTAssertEqual(fight.name, "The Fog Dragon")
        XCTAssertEqual(fight.icon, "fogDragon")
        XCTAssertTrue(fight.quarry)
        XCTAssertEqual(fight.phase, 2)
        XCTAssertEqual(fight.phases, 3)
        XCTAssertEqual(fight.tenthsLeft, 6, "300 of this phase's 500 before the journey reaches it")
        XCTAssertEqual(fight.phasesBroken, 1)
    }

    func testANearLegendIsTheFightWithoutAQuarry() throws {
        let foe = try XCTUnwrap(legend(phase: 1, left: 500, at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 100)).foe)
        let far = creature("Fen Troll", at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 900))
        let fight = try XCTUnwrap(WatchFight.pick(
            objects: [far, foe], quarryId: nil, from: start, isFought: { _ in true },
            healthLeft: { $0 == foe.id ? 0.42 : 0.9 }, isDefeated: { _ in false }
        ))
        XCTAssertEqual(fight.name, "The Fog Dragon")
        XCTAssertFalse(fight.quarry)
        XCTAssertEqual(fight.phase, 1)
        XCTAssertEqual(fight.tenthsLeft, 5)
    }

    func testABrokenPhaseLeavesTheNextWholeAndOnlyTheLastIsADefeat() throws {
        let second = try XCTUnwrap(legend(phase: 2, left: 120).foe)
        let broke = try XCTUnwrap(WatchFight.pick(
            objects: [second], quarryId: dragonId, from: start, isFought: { _ in true },
            healthLeft: { _ in 0 }, isDefeated: { _ in true }
        ))
        XCTAssertFalse(broke.defeated, "phase 2 broken: there is one more")
        XCTAssertEqual(broke.phase, 3)
        XCTAssertEqual(broke.tenthsLeft, 10, "the next phase stands whole: no more breaks today")
        XCTAssertEqual(broke.phasesBroken, 2)

        let last = try XCTUnwrap(legend(phase: 3, left: 40).foe)
        let down = try XCTUnwrap(WatchFight.pick(
            objects: [last], quarryId: dragonId, from: start, isFought: { _ in true },
            healthLeft: { _ in 0 }, isDefeated: { _ in true }
        ))
        XCTAssertTrue(down.defeated)
        XCTAssertEqual(down.tenthsLeft, 0)
        XCTAssertEqual(down.phasesBroken, 3)

        // A creature seen off is defeated, as before.
        let troll = creature("Fen Troll", at: start)
        let gone = try XCTUnwrap(WatchFight.pick(objects: [troll], quarryId: troll.id, from: start, isFought: { _ in true },
                                                 healthLeft: { _ in 0 }, isDefeated: { _ in true }))
        XCTAssertTrue(gone.defeated)
        XCTAssertFalse(gone.isLegend)
    }

    // MARK: Phase broken

    func testPhaseBrokenIsOneFightTapAndItsMarkInTheOverlay() throws {
        let foe = try XCTUnwrap(legend(phase: 1).foe)
        let event = try XCTUnwrap(WatchObjectiveCompleted.phaseBroken(foe, icon: "fogDragon"))
        XCTAssertEqual(event.outcome, "PHASE")
        XCTAssertTrue(event.isPhaseBroken)
        XCTAssertEqual(event.title, "The Fog Dragon")
        XCTAssertEqual(event.icon, "fogDragon")
        XCTAssertEqual(event.detail, "2 phases left")
        XCTAssertTrue(WristTap.fight.contains(event.tap), "a fight's tap")
        XCTAssertFalse(WristTap.turns.contains(event.tap), "never a turn's")
        XCTAssertEqual(WatchObjectiveCompleted.phaseBroken(name: "X", icon: nil, broken: 2, of: 3).detail, "One phase left")
        XCTAssertEqual(WatchObjectiveCompleted.phaseBroken(name: "X", icon: nil, broken: 3, of: 3).detail, "Defeated!")
        XCTAssertNil(WatchObjectiveCompleted.phaseBroken(creature("Fen Troll", at: start), icon: nil), "a creature has no phases")

        let decoded = try WatchMessages.objectiveCompleted(from: WatchMessages.objectiveCompleted(event))
        XCTAssertEqual(decoded, event)
        // An older Watch reads the outcome as a heading it shows as written.
        struct OldObjectiveCompleted: Decodable {
            var title: String
            var detail: String?
            var outcome: String?
        }
        let older = try JSONCoding.decode(OldObjectiveCompleted.self, from: JSONCoding.encode(event))
        XCTAssertEqual(older.outcome, "PHASE")
        XCTAssertEqual(older.detail, "2 phases left")
    }

    // MARK: The Watch map

    func testTheLegendIsOnTheMapAfterTheQuarryAndBeforeBountiesAndTheLairAsItsMiddle() throws {
        let route = (0...10).map { GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: Double($0) * 300) }
        let foe = try XCTUnwrap(legend(at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 1_200)).foe)
        let bounty = creature("Fen Troll", at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 100), bounty: true)
        let quarry = creature("Bog Wraith", at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 50))
        var lair = WorldObject(id: UUID(), kind: .unknown, latitude: 51.501, longitude: -0.095, name: "Southwark Park lair",
                               rewardAC: 0, expiresAt: Date(timeIntervalSince1970: 9_999_999))
        lair.lair = LairInfo(cells: [[51.501, -0.095]], visited: [0], need: 5)
        let marks = WatchWorldMarks.select(objects: [bounty, lair, foe, quarry, foe], route: route, start: start, quarryId: quarry.id) {
            $0.isLegend ? "fogDragon" : ($0.isLair ? "lair" : nil)
        }
        XCTAssertEqual(marks.map(\.name), ["Bog Wraith", "The Fog Dragon", "Fen Troll", "Southwark Park lair"], "the legend once")
        let dragon = marks[1]
        XCTAssertEqual(dragon.kind, WatchWorldMark.legend)
        XCTAssertTrue(dragon.isLegend)
        XCTAssertFalse(dragon.isQuarry)
        XCTAssertEqual(dragon.icon, "fogDragon")
        XCTAssertEqual(dragon.speciesId, "fog-dragon")
        XCTAssertEqual(marks[3].kind, WatchWorldMark.lair)

        // Planned for, it leads even from far off.
        let far = try XCTUnwrap(legend(at: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: 6_000)).foe)
        let planned = WatchWorldMarks.select(objects: [bounty, far], route: route, start: start, quarryId: dragonId)
        XCTAssertEqual(planned.first?.kind, WatchWorldMark.legend)
        XCTAssertEqual(planned.first?.isQuarry, true)
        XCTAssertFalse(WatchWorldMarks.select(objects: [far], route: route, start: start).contains { $0.isLegend }, "out of reach")

        // The map's marks round trip, and an older Watch reads the kinds as plain strings.
        let summary = WatchRouteSummary(questTitle: nil, instructions: [], objectives: [], totalDistanceMeters: 3_000, worldMarks: marks)
        XCTAssertEqual(try WatchMessages.routeSummary(from: WatchMessages.routeSummary(summary)).worldMarks, marks)
    }

    func testALegendWithABrokenPhaseStaysOnTheMapUntilItIsDefeated() throws {
        let second = try XCTUnwrap(legend(phase: 2).foe)
        let troll = creature("Fen Troll", at: start)
        let done = UUID()
        let gone = try XCTUnwrap(WatchWorldMarks.gone(claimed: [second.id, troll.id], done: [done], objects: [second, troll]))
        XCTAssertEqual(Set(gone), [troll.id, done], "phase 2 broken: one more to go, so it stays")
        XCTAssertEqual(gone, gone.sorted { $0.uuidString < $1.uuidString }, "the same set is the same message")
        let last = try XCTUnwrap(legend(phase: 3).foe)
        XCTAssertEqual(WatchWorldMarks.gone(claimed: [last.id], done: [], objects: [last]), [last.id], "its last phase: defeated")
        XCTAssertNil(WatchWorldMarks.gone(claimed: [second.id], done: [], objects: [second]), "nothing gone")
    }

    // MARK: Journey's end

    func testJourneysEndListsTheLegendTheLairAndTreasure() throws {
        var summary = SampleData.sampleAdventureSummary
        summary.legend = LegendOutcome(id: dragonId, name: "The Fog Dragon", icon: "fogDragon", phaseBefore: 2, phaseAfter: 3,
                                       healthLeft: 500, healthMax: 500, damage: 380, kinds: ["GROUND": 380], phaseBroken: true,
                                       line: "Phase broken! The Fog Dragon is down to its last phase.")
        summary.lair = LairOutcome(name: "Southwark Park", visited: 3, need: 5)
        summary.treasureFound = TreasureFinds([TreasureFound(coins: 120)])
        let end = WatchJourneyEnd(summary: summary)
        XCTAssertEqual(end.legend, WatchEndLine(text: "Phase broken! The Fog Dragon is down to its last phase.", icon: "fogDragon"))
        XCTAssertEqual(end.lair, WatchEndLine(text: "Lair: 3 of 5 tiles", icon: "lair", detail: "Southwark Park"))
        XCTAssertEqual(end.treasureFound, WatchEndLine(text: "Buried treasure found", icon: "openChest", detail: "+120 coins"))

        let decoded = try WatchMessages.journeyEnd(from: WatchMessages.journeyEnd(end))
        XCTAssertEqual(decoded, end)

        // Nothing to say of them: none.
        let plain = WatchJourneyEnd(summary: SampleData.sampleAdventureSummary)
        XCTAssertNil(plain.legend)
        XCTAssertNil(plain.lair)
        XCTAssertNil(plain.treasureFound)

        // An older phone's Journey's end has none of them.
        let old = try JSONCoding.decode(WatchJourneyEnd.self, json: """
        {"creaturesDefeated": 1, "chestsOpened": 0, "coins": 40, "xp": 120, "finds": []}
        """)
        XCTAssertNil(old.legend)
        XCTAssertNil(old.treasureFound)
        XCTAssertEqual(old.coins, 40)
    }

    func testTheLegendsLineIsTheServersElseOneMadeFromWhatHappened() {
        XCTAssertEqual(WatchEndLine.legend(name: "The Fog Dragon", icon: nil, line: "  ", damage: 0, phaseBroken: false, defeated: true)?.text,
                       "The Fog Dragon is defeated!")
        let broke = WatchEndLine.legend(name: "The Fog Dragon", icon: nil, line: nil, damage: 500, phaseBroken: true, defeated: false)
        XCTAssertEqual(broke?.text, "Phase broken!")
        XCTAssertEqual(broke?.detail, "The Fog Dragon")
        XCTAssertEqual(WatchEndLine.legend(name: "The Fog Dragon", icon: nil, line: nil, damage: 140, phaseBroken: false, defeated: false)?.text,
                       "The Fog Dragon took 140 damage")
        XCTAssertNil(WatchEndLine.legend(name: "The Fog Dragon", icon: nil, line: nil, damage: 0, phaseBroken: false, defeated: false))
        XCTAssertEqual(WatchEndLine.lair(name: "Southwark Park", visited: 6, need: 5, done: true).text, "Great chest opened")
        XCTAssertEqual(WatchEndLine.lair(name: nil, visited: 9, need: 5, done: false).text, "Lair: 5 of 5 tiles")
        XCTAssertEqual(WatchEndLine.treasure(count: 2, coins: 0), WatchEndLine(text: "2 buried treasures found", icon: "openChest"))
    }

    // MARK: The complication

    func testALegendThatIsTheQuarryIsOnTheFaceInGold() throws {
        let mark = WatchWorldMark(id: dragonId, kind: WatchWorldMark.legend, name: "The Fog Dragon", latitude: 51.5, longitude: -0.1,
                                  icon: "fogDragon", speciesId: "fog-dragon", quarry: true)
        let quarry = WatchQuarry(mark: mark)
        XCTAssertTrue(quarry.isLegend)
        let face = WatchComplication(idle: nil, quarry: quarry)
        XCTAssertEqual(face.mark, .legend(name: "The Fog Dragon", icon: "fogDragon", speciesId: "fog-dragon"))
        XCTAssertEqual(face.mark?.isQuarry, true)
        XCTAssertEqual(face.mark?.isLegend, true)
        XCTAssertFalse(WatchQuarry(name: "Fen Troll").isLegend)

        // Kept in the app group as written; one kept by 0.7.3 reads as a creature.
        let kept = try JSONCoding.decode(WatchQuarry.self, from: JSONCoding.encode(quarry))
        XCTAssertEqual(kept, quarry)
        let older = try JSONCoding.decode(WatchQuarry.self, json: #"{"name": "Fen Troll", "icon": "troll"}"#)
        XCTAssertFalse(older.isLegend)
    }
}
