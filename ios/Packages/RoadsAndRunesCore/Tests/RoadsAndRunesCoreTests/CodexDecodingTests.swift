@testable import RoadsAndRunesCore
import XCTest

/// `GET /codex` as docs/API.md shows it, and the fields 0.6.0 added to things
/// older servers never sent.
final class CodexDecodingTests: XCTestCase {
    func testCodexFromAPIDocSample() throws {
        let json = """
        {
          "chapters": [{"id": "WORLD", "title": "The Old Roads"}, {"id": "CREATURES", "title": "Things that settle"}],
          "entries": [{"id": "the-fog", "chapter": "WORLD", "title": "The fog", "body": ["Ground you have not read."],
                       "by": "enid-sallow", "byName": "Enid Sallow", "characterClass": null}],
          "creatures": [{
            "id": "fen-troll", "name": "Fen Troll", "family": "WATER", "flavour": "Sleeps by the water; wakes for footsteps.",
            "hint": "Keeps to water.", "page": "…", "leaves": "a bridge nail",
            "wants": ["ROAD", "RUNE"], "minds": ["WORD"], "rune": "dagaz",
            "elders": [{"tier": 2, "name": "Culvert Troll", "flavour": "…", "seen": true},
                       {"tier": 3, "name": "Old Arch", "flavour": "…", "seen": false}],
            "sigil": {"body": "hulk", "feature": "horns", "mark": "water"},
            "state": "MET", "seenCount": 3, "seenOffCount": 1,
            "firstSeenAt": "2026-10-01T09:00:00Z", "lastSeenOffAt": "2026-10-02T09:00:00Z"
          }],
          "runes": [{"id": "raido", "name": "Raido", "order": 5, "six": "ROAD", "gloss": "The road-rune.", "lends": "the road",
                     "roadForm": "LOOP", "state": "HELD", "found": 2},
                    {"id": "fehu", "name": "Fehu", "order": 1, "six": "TRADE", "gloss": "The toll-rune.", "lends": "coin",
                     "roadForm": null, "state": "SOMETHING_NEW", "found": 0}],
          "sixes": [{"id": "ROAD", "name": "the Road Six", "how": "Found lying anywhere."}],
          "people": [{"id": "ada-pym", "name": "Ada Pym", "role": "Keeps the board", "posts": "ANY", "page": "…",
                      "pageBy": "enid-sallow", "lines": ["Wanted: somebody."]}],
          "counts": {"creaturesSeenOff": 1, "creaturesSeen": 2, "creaturesTotal": 12, "runesHeld": 1, "runesTotal": 24}
        }
        """
        let codex = try JSONCoding.decode(Codex.self, json: json)
        XCTAssertEqual(codex.creatures.first?.state, .met)
        XCTAssertEqual(codex.creatures.first?.sigil, CreatureSigil(body: "hulk", feature: "horns", mark: "water"))
        XCTAssertEqual(codex.runes.first?.roadForm, "LOOP")
        XCTAssertEqual(codex.runes.last?.state, .unknown, "a state this build does not know decodes, not throws")
        XCTAssertEqual(codex.entries(in: "WORLD").map(\.id), ["the-fog"])
        XCTAssertEqual(codex.counts.creaturesTotal, 12)
    }

    func testAMonsterFromAnOlderServerHasNoSpecies() throws {
        let old = try JSONCoding.decode(MonsterInfo.self, json: #"{"hp": 100, "flavour": "x", "killMethods": []}"#)
        XCTAssertNil(old.speciesId)
        XCTAssertNil(old.sigil)
        let new = try JSONCoding.decode(MonsterInfo.self, json: """
        {"hp": 100, "killMethods": [], "speciesId": "rook-lord", "sigil": {"body": "bird", "feature": "crown", "mark": "tree"}}
        """)
        XCTAssertEqual(new.sigil?.feature, "crown")
    }

    func testAClassFromAnOlderServerHasNoGuild() throws {
        let old = try JSONCoding.decode(ClassInfo.self, json: #"{"id": "EXPLORER", "name": "Explorer", "tagline": "t", "description": "d", "enabled": true}"#)
        XCTAssertNil(old.crest)
    }
}
