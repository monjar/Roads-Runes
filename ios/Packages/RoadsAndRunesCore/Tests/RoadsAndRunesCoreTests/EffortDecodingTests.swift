import XCTest
@testable import RoadsAndRunesCore

/// What 0.6.1 adds to the API, as the server sends it (docs/API.md), and the same
/// payloads from a server before it: every new field is optional.
final class EffortDecodingTests: XCTestCase {
    private let decoder = JSONCoding.makeDecoder()

    func testAMonsterCarriesItsHoldAndWhatItWants() throws {
        let json = #"""
        {"hp": 200, "killMethods": [], "speciesId": "grey-stag", "holdMax": 220, "holdLeft": 140,
         "wants": ["CLIMB", "RUNE"], "minds": ["WORD"], "rune": "kenaz", "roadForm": "TRIANGLE", "unpassedDays": 41}
        """#
        let monster = try decoder.decode(MonsterInfo.self, from: Data(json.utf8))
        XCTAssertTrue(monster.foughtByEffort)
        XCTAssertEqual(monster.holdLeft, 140)
        XCTAssertEqual(monster.roadForm, "TRIANGLE")
        let old = try decoder.decode(MonsterInfo.self, from: Data(#"{"hp": 100, "killMethods": []}"#.utf8))
        XCTAssertFalse(old.foughtByEffort)
    }

    func testTheSummaryCarriesEachFight() throws {
        let json = #"""
        {"claimed": [], "missed": [{"id": "8a1f0b2c-0000-4000-8000-00000000a001", "kind": "MONSTER", "name": "Grey Stag", "reason": "LOOSENED"}],
         "fights": [{"id": "8a1f0b2c-0000-4000-8000-00000000a001", "name": "Grey Stag", "speciesId": "grey-stag", "tier": 3, "bounty": false,
                     "latitude": 51.49, "longitude": -0.03, "outcome": "LOOSENED", "holdMax": 400, "holdBefore": 400, "holdAfter": 31,
                     "damage": {"ROAD": 12, "CLIMB": 300, "CARRIED": 57}, "units": {"ROAD": 1200.0, "CLIMB": 120.0},
                     "finisher": null, "runeLanded": false, "wordLanded": false,
                     "wouldHaveDone": {"kind": "CLIMB", "units": 13, "unit": "m"}, "expiresAt": "2026-10-07T09:00:00+00:00"}]}
        """#
        let world = try decoder.decode(WorldObjectOutcome.self, from: Data(json.utf8))
        let fight = try XCTUnwrap(world.fights?.first)
        XCTAssertEqual(fight.taken, 369)
        XCTAssertEqual(fight.damage["CARRIED"], 57)
        XCTAssertEqual(fight.wouldHaveDone?.units, 13)
        XCTAssertNotNil(fight.coordinate)
    }

    func testTheRideAndCharacterCarryTheSheetAndConfigTheConstants() throws {
        let sheet = #"""
        {"version": 1, "characterClass": "EXPLORER", "overallLevel": 4, "classLevel": 3, "damagePct": {"GROUND": 0.3},
         "runeThreshold": 0.22, "runeReachMeters": 1000.0, "coinPct": {}, "xpPct": {}}
        """#
        let decoded = try decoder.decode(CharacterSheet.self, from: Data(sheet.utf8))
        XCTAssertEqual(decoded.damagePct["GROUND"], 0.3)

        let combat = try decoder.decode(CombatConstants.self, from: Data(#"{"engageMeters": 140, "rates": {"ROAD": 0.02}}"#.utf8))
        XCTAssertEqual(combat.engageMeters, 140)
        XCTAssertEqual(combat.rates["ROAD"], 0.02)
        XCTAssertEqual(combat.groundMeters, 1000, "a constant the server did not send keeps its default")
    }
}
