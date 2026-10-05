import XCTest
@testable import RoadsAndRunesCore

/// Legends, lairs and treasure maps (0.8.0) as the contract's payloads have them,
/// and every new field on an older type read from a server that never sent it.
final class LegendDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: Data(json.utf8))
    }

    static let legendJSON = #"""
    {"id": "c0ffee00-0000-4000-8000-00000000d001", "speciesId": "fog-dragon", "name": "The Fog Dragon", "icon": "fogDragon",
     "flavour": "A dragon that sleeps where the map is blank.", "page": "It curls up on ground nobody has explored.",
     "latitude": 51.505, "longitude": -0.02, "anchorName": "Stave Hill", "status": "AWAKE", "phase": 2,
     "phases": [
       {"n": 1, "weakTo": ["GROUND"], "resists": ["WORD"], "healthMax": 500, "healthLeft": 0, "broken": true},
       {"n": 2, "weakTo": ["GROUND", "ROAD"], "resists": ["WORD"], "healthMax": 500, "healthLeft": 360, "broken": false},
       {"n": 3, "weakTo": ["RUNE"], "resists": ["WORD"], "healthMax": 500, "healthLeft": 500, "broken": false}
     ],
     "healthLeft": 860, "healthMax": 1500, "moved": false, "wokeAt": "2026-09-26T08:00:00Z", "lastHitAt": "2026-10-03T18:12:00.5Z",
     "healsPerWeek": 50, "rune": "hagalaz", "sleepsAfterDays": 28,
     "journeys": [
       {"rideId": "66666666-6666-4666-8666-666666666601", "date": "2026-09-27", "damage": 320, "phase": 1},
       {"rideId": "66666666-6666-4666-8666-666666666602", "date": "2026-09-30", "damage": 180, "phase": 1},
       {"rideId": "66666666-6666-4666-8666-666666666603", "date": "2026-10-03T18:12:00Z", "damage": 140, "phase": 2}
     ]}
    """#

    func testALegendDecodes() throws {
        let legend = try decode(Legend.self, Self.legendJSON)
        XCTAssertEqual(legend.name, "The Fog Dragon")
        XCTAssertTrue(legend.isAwake)
        XCTAssertEqual(legend.phases.map(\.n), [1, 2, 3])
        XCTAssertEqual(legend.currentPhase?.n, 2)
        XCTAssertEqual(legend.currentPhase?.weakTo, ["GROUND", "ROAD"])
        XCTAssertEqual(legend.phaseLine, "Phase 2 of 3")
        XCTAssertEqual(legend.healsPerWeek, 50)
        XCTAssertEqual(legend.sleepsAfterDays, 28)
        XCTAssertEqual(legend.journeys?.count, 3)
        XCTAssertNotNil(legend.journeys?.first?.date, "a day alone reads as a date")
        XCTAssertNotNil(legend.lastHitAt)
    }

    /// The notches on a phase's bar: where each journey had taken it to.
    func testEachJourneyIsANotchOnItsPhase() throws {
        let legend = try decode(Legend.self, Self.legendJSON)
        XCTAssertEqual(legend.notches(phase: 1), [0.64, 1.0])
        XCTAssertEqual(legend.notches(phase: 2), [0.28])
        XCTAssertEqual(legend.notches(phase: 3), [])
    }

    /// The legend as a journey fights it: this phase's health, weak to and resisting what this phase is.
    func testTheLegendIsFoughtAsItsCurrentPhase() throws {
        let legend = try decode(Legend.self, Self.legendJSON)
        let foe = try XCTUnwrap(legend.foe)
        XCTAssertEqual(foe.id, legend.id)
        XCTAssertEqual(foe.kind, .monster)
        XCTAssertTrue(foe.isLegend)
        XCTAssertEqual(foe.monster?.holdMax, 500)
        XCTAssertEqual(foe.monster?.holdLeft, 360)
        XCTAssertEqual(foe.monster?.wants, ["GROUND", "ROAD"])
        XCTAssertEqual(foe.monster?.minds, ["WORD"])
        XCTAssertEqual(foe.monster?.phase, 2)
        XCTAssertEqual(foe.monster?.phases, 3)
        XCTAssertGreaterThanOrEqual(foe.tier, 2, "what works against elders works against it")
        XCTAssertFalse(SampleData.sampleMonster.isLegend)

        var asleep = legend
        asleep.status = LegendStatus.dormant
        XCTAssertNil(asleep.foe, "asleep, it is off the map and fights nothing")
    }

    /// Only what places it is required; everything else falls back.
    func testABareLegendStillDecodes() throws {
        let legend = try decode(Legend.self, #"{"id": "c0ffee00-0000-4000-8000-00000000d001", "name": "The Hill King", "latitude": 51.5, "longitude": 0.1}"#)
        XCTAssertEqual(legend.status, LegendStatus.awake)
        XCTAssertEqual(legend.phase, 1)
        XCTAssertTrue(legend.phases.isEmpty)
        XCTAssertNil(legend.foe, "no phases, nothing to fight")
        XCTAssertFalse(legend.moved)
        XCTAssertEqual(legend.phaseLine, "Phase 1 of 3")
    }

    func testTheLegendsListDecodes() throws {
        let json = #"""
        {"awake": \#(Self.legendJSON),
         "defeated": [{"id": "c0ffee00-0000-4000-8000-00000000d004", "speciesId": "hill-king", "name": "The Hill King", "icon": "hillKing",
                       "defeatedAt": "2026-09-01T10:00:00Z", "rune": "uruz"}],
         "creaturesUntilNext": null}
        """#
        let state = try decode(LegendsState.self, json)
        XCTAssertEqual(state.awake?.speciesId, "fog-dragon")
        XCTAssertEqual(state.defeated.map(\.name), ["The Hill King"])
        XCTAssertNil(state.creaturesUntilNext)
        XCTAssertTrue(state.sleeping.isEmpty, "an older answer has none asleep")
        XCTAssertEqual(state.met.map(\.name), ["The Fog Dragon", "The Hill King"])

        let none = try decode(LegendsState.self, #"{"awake": null, "defeated": [], "creaturesUntilNext": 2}"#)
        XCTAssertNil(none.awake)
        XCTAssertEqual(none.creaturesUntilNext, 2)
        XCTAssertNil(try decode(LegendsState.self, "{}").awake)
    }

    // MARK: Journey's end

    /// As `legends/service.py fold_ride`, `lairs.py` and `inventory/treasure.py` write them.
    func testTheSummaryCarriesTheLegendTheLairAndTheTreasure() throws {
        let json = #"""
        {"legend": {"id": "c0ffee00-0000-4000-8000-00000000d001", "speciesId": "fog-dragon", "name": "The Fog Dragon", "icon": "fogDragon",
                    "phaseBefore": 2, "phaseAfter": 3, "healthLeft": 500, "healthMax": 1500, "phaseHealthLeft": 500, "phaseHealthMax": 500,
                    "damage": 360, "kinds": {"GROUND": 240, "ROAD": 120}, "phaseBroken": true, "defeated": false, "heldOver": false,
                    "rewards": {"coins": 150, "xp": 300,
                                "items": [{"kind": "GEAR", "name": "Rowan Twig", "rarity": "RARE", "icon": "rowanTwig", "source": "LEGEND"},
                                          {"kind": "CONSUMABLE", "consumable": "TREASURE_MAP", "name": "Treasure map", "source": "LEGEND"}],
                                "rune": null, "title": null},
                    "line": "Phase broken! The Fog Dragon is down to its last phase."},
         "legendWoke": {"id": "c0ffee00-0000-4000-8000-00000000d005", "speciesId": "water-wyrm", "name": "The Water Wyrm",
                        "icon": "waterWyrm", "line": "A legend has woken: the Water Wyrm"},
         "lair": {"id": "c0ffee00-0000-4000-8000-00000000d002", "name": "Southwark Park lair", "visited": 5, "need": 5, "tiles": 7,
                  "newTiles": 2, "done": true, "endsAt": "2026-10-14T00:00:00+00:00",
                  "rewards": {"coins": 250, "items": [{"kind": "GEAR", "name": "Tinker's Satchel", "rarity": "RARE"}],
                              "rune": {"rune": "ingwaz", "new": true, "rank": 1, "shards": 0, "name": "Ingwaz"}},
                  "line": "You visited 5 of the lair's 7 tiles. The great chest is yours!"},
         "treasureFound": {"id": "c0ffee00-0000-4000-8000-00000000d003", "name": "Buried treasure", "clue": "By water.", "coins": 120,
                           "item": {"kind": "GEAR", "name": "Drover's Bell", "rarity": "RARE"}, "line": "You found the buried treasure!"}}
        """#
        let summary = try decode(SummaryExtras.self, json)
        let legend = try XCTUnwrap(summary.legend)
        XCTAssertTrue(legend.phaseBroken)
        XCTAssertEqual(legend.kinds["GROUND"], 240)
        XCTAssertEqual(legend.phaseLeft, 500)
        XCTAssertEqual(legend.healthMax, 1500, "the whole, over three phases")
        XCTAssertEqual(legend.fraction, 1)
        XCTAssertEqual(legend.rewards?.items?.first?.rarity, "RARE")
        XCTAssertEqual(legend.rewards?.items?.count, 2)
        XCTAssertNil(legend.rewards?.rune)
        XCTAssertEqual(summary.legendWoke?.line, "A legend has woken: the Water Wyrm")
        XCTAssertEqual(summary.lair?.done, true)
        XCTAssertEqual(summary.lair?.rewards?.rune?.rune, "ingwaz")
        XCTAssertEqual(summary.lair.map(LairCopy.outcome), "You visited 5 of the lair's 7 tiles. The great chest is yours!")
        XCTAssertEqual(summary.treasureFound?.finds.first?.coins, 120)
        XCTAssertEqual(summary.treasureFound?.finds.first?.treasureId, UUID(uuidString: "c0ffee00-0000-4000-8000-00000000d003"))
    }

    /// A defeat pays its Hard rune as the rune stone the server records, and a title, however they come.
    func testADefeatsRuneAndTitleReadEitherWay() throws {
        let object = try decode(LegendRewards.self, #"{"coins": 400, "rune": {"rune": "hagalaz", "name": "Hagalaz"}, "title": {"name": "Bane of the Fog Dragon"}}"#)
        XCTAssertEqual(object.rune?.rune, "hagalaz")
        XCTAssertEqual(object.title, "Bane of the Fog Dragon")
        let plain = try decode(LegendRewards.self, #"{"rune": "uruz", "title": "Bane of the Hill King", "item": {"kind": "GEAR", "name": "X"}}"#)
        XCTAssertEqual(plain.rune?.rune, "uruz")
        XCTAssertEqual(plain.title, "Bane of the Hill King")
        XCTAssertEqual(plain.items?.map(\.name), ["X"])
    }

    /// The whole summary from an older server: none of it, and nothing breaks.
    func testAnOlderSummaryHasNoneOfIt() throws {
        let older = try JSONCoding.makeDecoder().decode(AdventureSummary.self, from: Data(AdventureSummaryDecodingTests.json.utf8))
        XCTAssertNil(older.legend)
        XCTAssertNil(older.lair)
        XCTAssertTrue(older.treasures.isEmpty)
        // And a summary that has them goes round the phone's own cache intact.
        var summary = SampleData.sampleAdventureSummary
        summary.legend = SampleData.sampleLegendOutcome
        summary.lair = SampleData.sampleLairOutcome
        summary.treasureFound = TreasureFinds([SampleData.sampleTreasureFound])
        let again = try JSONCoding.makeDecoder().decode(AdventureSummary.self, from: try JSONCoding.encode(summary))
        XCTAssertEqual(again.legend, summary.legend)
        XCTAssertEqual(again.lair, summary.lair)
        XCTAssertEqual(again.treasures, summary.treasures)
    }

    func testTreasureFoundReadsAsOneAListOrTrue() throws {
        XCTAssertEqual(try decode(TreasureFinds.self, #"[{"coins": 120}, {"coins": 80}]"#).finds.count, 2)
        XCTAssertEqual(try decode(TreasureFinds.self, #"{"coins": 120}"#).finds.first?.coins, 120)
        XCTAssertEqual(try decode(TreasureFinds.self, "true").finds.count, 1)
        XCTAssertTrue(try decode(TreasureFinds.self, "false").finds.isEmpty)
    }

    func testALairsVisitedMayBeACountOrTheTiles() throws {
        XCTAssertEqual(try decode(LairOutcome.self, #"{"name": "Lair", "visited": [0, 2, 2, 5], "need": 5}"#).visited, 3)
        let count = try decode(LairOutcome.self, #"{"name": "Lair", "visited": 4, "need": 5}"#)
        XCTAssertEqual(count.visited, 4)
        XCTAssertFalse(count.done)
    }

    // MARK: The world

    /// A lair on `/world/objects`: a kind this build reads as unknown, so nothing
    /// that does not know lairs fights or draws it; its tiles ride along.
    func testALairDecodesAsAnUnknownKindWithItsTiles() throws {
        let json = #"""
        [{"id": "c0ffee00-0000-4000-8000-00000000d002", "kind": "LAIR", "status": "SPAWNED", "tier": 1, "latitude": 51.48,
          "longitude": -0.05, "name": "Southwark Park lair", "anchorName": "Southwark Park", "rewardAC": 250,
          "expiresAt": "2026-10-14T00:00:00Z",
          "lair": {"cells": [[51.48, -0.05], [51.483, -0.05], [51.4815, -0.046], [51.4785, -0.046], [51.477, -0.05], [51.4785, -0.054], [51.4815, -0.054]],
                   "visited": [0, 2, 5], "need": 5, "endsAt": "2026-10-14T00:00:00Z"}},
         {"id": "c0ffee00-0000-4000-8000-0000000000e1", "kind": "CHEST", "status": "SPAWNED", "tier": 1, "latitude": 51.49,
          "longitude": -0.04, "name": "Old chest", "rewardAC": 30, "expiresAt": "2026-10-06T00:00:00Z"}]
        """#
        let objects = try decode([WorldObject].self, json)
        let lair = try XCTUnwrap(objects.first)
        XCTAssertEqual(lair.kind, .unknown)
        XCTAssertTrue(lair.isLair)
        XCTAssertEqual(lair.lair?.cells.count, 7)
        XCTAssertEqual(lair.lair?.visitedCount, 3)
        XCTAssertEqual(lair.lair?.need, 5)
        XCTAssertFalse(lair.lair?.done ?? true)
        XCTAssertNil(objects[1].lair, "an older object has no lair")
        XCTAssertFalse(objects[1].isLair)

        let tiles = try XCTUnwrap(lair.lair?.tiles(indexing: FakeCellIndexing(), resolution: 9))
        XCTAssertEqual(tiles.count, 7)
        XCTAssertEqual(tiles.filter(\.visited).map(\.index), [0, 2, 5])
        XCTAssertTrue(tiles.allSatisfy { $0.outline.count >= 3 })
    }

    // MARK: Treasure maps

    func testATreasureMapsUseGivesAClueAndNoPlace() throws {
        let json = #"""
        {"clue": "Buried by water, in a green place, about 2 km north-east of here.",
         "treasureId": "c0ffee00-0000-4000-8000-00000000d003",
         "inventory": {"slots": [], "consumables": [{"id": "TREASURE_MAP", "name": "Treasure map", "text": "A map.", "count": 0}]}}
        """#
        let result = try decode(ConsumableUseResult.self, json)
        XCTAssertEqual(result.treasureClue?.clue, "Buried by water, in a green place, about 2 km north-east of here.")
        XCTAssertNil(result.coordinate, "a clue is never a place")
        XCTAssertEqual(result.inventory?.count(of: ConsumableId.treasureMap), 0)
        XCTAssertTrue(ConsumableId.usableFromTheBag(ConsumableId.treasureMap))
        XCTAssertTrue(ConsumableId.needsLocation(ConsumableId.treasureMap))
        // A map piece's answer, as before, has no clue.
        XCTAssertNil(try decode(ConsumableUseResult.self, #"{"revealedTiles": 7, "placeName": "The Crown"}"#).treasureClue)
    }

    func testOpenCluesReadFromAnyShape() throws {
        let one = #"{"treasureId": "c0ffee00-0000-4000-8000-00000000d003", "clue": "By a hill.", "buriedAt": "2026-10-04T10:00:00Z"}"#
        XCTAssertEqual(try decode(TreasureClues.self, "[\(one)]").clues.count, 1)
        XCTAssertEqual(try decode(TreasureClues.self, #"{"clues": [\#(one)]}"#).clues.first?.clue, "By a hill.")
        XCTAssertEqual(try decode(TreasureClues.self, one).clues.count, 1)
        XCTAssertTrue(try decode(TreasureClues.self, "[]").clues.isEmpty)
        XCTAssertTrue(try decode(TreasureClues.self, #"{"clues": []}"#).clues.isEmpty)
    }

    // MARK: The sheet

    func testTheVersionFiveSheetCarriesTheCapstones() throws {
        let sheet = try decode(CharacterSheet.self, #"""
        {"version": 5, "characterClass": "EXPLORER", "overallLevel": 30, "classLevel": 20, "damagePct": {}, "runeThreshold": 0.22,
         "runeReachMeters": 1000, "vsLegendsPct": {"GROUND": 0.25}, "legendWordRadiusMeters": 500}
        """#)
        XCTAssertEqual(sheet.vsLegendsPct?["GROUND"], 0.25)
        XCTAssertEqual(sheet.legendWordRadiusMeters, 500)
        let older = try decode(CharacterSheet.self, #"""
        {"version": 4, "characterClass": "WIZARD", "overallLevel": 3, "classLevel": 3, "damagePct": {}, "runeThreshold": 0.22, "runeReachMeters": 1000}
        """#)
        XCTAssertNil(older.vsLegendsPct)
        XCTAssertNil(older.legendWordRadiusMeters)
    }
}

/// The summary's new parts alone, so the test does not need a whole ride.
private struct SummaryExtras: Decodable {
    var legend: LegendOutcome?
    var legendWoke: LegendWoke?
    var lair: LairOutcome?
    var treasureFound: TreasureFinds?
}
