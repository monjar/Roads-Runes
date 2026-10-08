import XCTest
@testable import RoadsAndRunesCore

/// What 0.7.0 adds to the API, as the server sends it (docs/API.md).
final class RunesDecodingTests: XCTestCase {
    private let decoder = JSONCoding.makeDecoder()

    func testRunesSlotsAndWhatTheNextRankCosts() throws {
        let json = #"""
        {"runes": [{"id": "raido", "name": "Raido", "six": "ROAD", "gloss": "The road-rune.", "roadForm": "LOOP", "held": true, "rank": 1,
                    "shards": 2, "inscribed": true, "rule": "The opening blow counts 2× at contact.", "nextRank": {"shards": 2, "coins": 100}},
                   {"id": "laguz", "name": "Laguz", "six": "GROUND", "gloss": null, "roadForm": null, "held": false, "rank": 0, "shards": 0,
                    "inscribed": false, "rule": "…", "nextRank": null}],
         "inscribed": ["raido"], "slots": 1, "slotsAtLevel": [1, 10, 25]}
        """#
        let state = try decoder.decode(RunesState.self, from: Data(json.utf8))
        XCTAssertTrue(state.runes[0].canRaise)
        XCTAssertFalse(state.runes[1].canRaise)
        XCTAssertEqual(state.slotsAtLevel, [1, 10, 25])
    }

    func testCutsDeedsAndWhatAnOutingDidForThem() throws {
        let cuts = try decoder.decode([RuneCutInfo].self, from: Data(#"""
        [{"runeId": "raido", "name": "Raido", "latitude": 51.49, "longitude": -0.03, "woke": true, "source": "WAKING",
          "placeName": null, "cutAt": "2026-10-04T09:00:00+00:00", "rideId": "x"}]
        """#.utf8))
        XCTAssertEqual(cuts.first?.coordinate.latitude, 51.49)
        let deeds = try decoder.decode(DeedsState.self, from: Data(#"""
        {"deeds": [{"id": "HAND", "name": "Hand", "what": "Runes cut with your track", "unit": "runes", "value": 1, "tier": 1,
                    "next": 5, "title": "First Cut", "frame": "hand-1"}],
         "records": [{"id": "RECORD_HIGHEST", "name": "Highest point reached", "unit": "m", "value": null}]}
        """#.utf8))
        XCTAssertEqual(deeds.deeds.first?.title, "First Cut")
        XCTAssertNil(deeds.records.first?.value)
        struct Part: Decodable { var runesFound: [RuneFound]?; var deeds: DeedsOutcome? }
        let part = try decoder.decode(Part.self, from: Data(#"""
        {"runesFound": [{"rune": "kenaz", "new": true, "rank": 1, "shards": 0}],
         "deeds": {"reached": [{"deed": "HAND", "name": "Hand", "tier": 1, "title": "First Cut", "frame": "hand-1"}], "records": []}}
        """#.utf8))
        XCTAssertEqual(part.runesFound?.first?.new, true)
        XCTAssertEqual(part.deeds?.reached.first?.title, "First Cut")
    }

    func testTheSheetCarriesTheRunesAndThePhoneFollowsWhatItCan() throws {
        let sheet = try decoder.decode(CharacterSheet.self, from: Data(#"""
        {"version": 3, "characterClass": "WIZARD", "overallLevel": 12, "classLevel": 8, "damagePct": {}, "runeThreshold": 0.3,
         "runeReachMeters": 2000, "inscribed": {"raido": 1, "ansuz": 1, "kenaz": 2},
         "rules": {"CARRIED_SCALE": 2.0, "WORD_RADIUS_M": 1000, "REVEAL_RINGS": 2}}
        """#.utf8))
        let cfg = sheet.fightConstants(CombatConstants())
        XCTAssertEqual(cfg.carriedFraction, CombatConstants().carriedFraction * 2, accuracy: 1e-9)
        XCTAssertEqual(cfg.wordRadiusMeters, 1000)
        XCTAssertEqual(sheet.sightMeters, 600)
        let plain = try decoder.decode(CharacterSheet.self, from: Data(#"""
        {"version": 1, "characterClass": "EXPLORER", "overallLevel": 1, "classLevel": 1, "damagePct": {}, "runeThreshold": 0.22, "runeReachMeters": 1000}
        """#.utf8))
        XCTAssertEqual(plain.fightConstants(CombatConstants()), CombatConstants())
    }

    func testTheNewObjectivesDecodeAndCarryIsFollowedOnThePhone() throws {
        XCTAssertEqual(try decoder.decode(ObjectiveType.self, from: Data(#""INSCRIBE_RUNE""#.utf8)), .inscribeRune)
        XCTAssertEqual(try decoder.decode(ObjectiveType.self, from: Data(#""CARRY""#.utf8)), .carry)
        XCTAssertEqual(try decoder.decode(ObjectiveType.self, from: Data(#""SOMETHING_NEW""#.utf8)), .unknown)
    }
}
