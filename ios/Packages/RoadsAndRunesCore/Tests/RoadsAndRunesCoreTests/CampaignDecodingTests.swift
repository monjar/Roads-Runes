import XCTest
@testable import RoadsAndRunesCore

/// What 0.6.2 adds to the API, as the server sends it (docs/API.md); every field
/// is optional, so the same payloads from an older server still decode.
final class CampaignDecodingTests: XCTestCase {
    private let decoder = JSONCoding.makeDecoder()

    func testAnArcSaysItsActChapterAndTrackAndAStepCanWait() throws {
        let json = #"""
        {"slug": "what-settles", "title": "What Settles", "description": "…", "characterClass": null, "minLevel": 1,
         "unlocked": false, "track": "MAIN", "act": 1, "actTitle": "The Board", "chapter": 2, "after": "first-light",
         "giver": "ada-pym", "reward": {"title": "Somebody", "ac": 150},
         "quests": [{"slug": "a", "sequence": 1, "title": "Something in the Way", "description": "…", "state": "WAITING",
                     "waitingReason": "Waiting for something to settle near you.", "questId": null}]}
        """#
        let arc = try decoder.decode(StoryArc.self, from: Data(json.utf8))
        XCTAssertTrue(arc.isCampaign)
        XCTAssertEqual(arc.actTitle, "The Board")
        XCTAssertEqual(arc.reward?.title, "Somebody")
        XCTAssertEqual(arc.quests.first?.state, .waiting)
        XCTAssertEqual(arc.quests.first?.waitingReason, "Waiting for something to settle near you.")

        let old = try decoder.decode(StoryArc.self, from: Data(#"{"slug": "x", "title": "X", "description": "", "minLevel": 1, "unlocked": true, "quests": []}"#.utf8))
        XCTAssertNil(old.track)
        XCTAssertFalse(old.isCampaign)
    }

    func testANoticeCarriesWhoPostedIt() throws {
        let json = #"{"hook": "…", "completion": "Seen off.", "source": "composed", "poster": {"castId": "nell-foss", "name": "Nell Foss", "line": "By the pond."}}"#
        let narrative = try decoder.decode(QuestNarrative.self, from: Data(json.utf8))
        XCTAssertEqual(narrative.poster?.name, "Nell Foss")
        XCTAssertNil(try decoder.decode(QuestNarrative.self, from: Data(#"{"hook": "…"}"#.utf8)).poster)
    }

    func testTitlesTheWeekAndTheChoice() throws {
        let titles = try decoder.decode([TitleInfo].self, from: Data(#"""
        [{"slug": "level-5", "name": "Familiar Face", "source": "LEVEL", "how": "Reach level 5.", "earned": true,
          "earnedAt": "2026-10-04T09:00:00+00:00", "worn": true},
         {"slug": "level-10", "name": "Roadwise", "source": "LEVEL", "how": "Reach level 10.", "earned": false, "earnedAt": null, "worn": false}]
        """#.utf8))
        XCTAssertEqual(titles.filter(\.earned).map(\.name), ["Familiar Face"])

        let week = try decoder.decode(WeekNotice.self, from: Data(#"""
        {"week": "2026-W41", "kind": "OUTINGS", "title": "Three outings this week.", "line": "Pinned Monday.", "postedBy": "Ada Pym",
         "target": 3, "unit": "outings", "progress": 2, "done": false, "paid": false, "coins": 150, "xp": 200, "endsAt": "2026-10-12T00:00:00+00:00"}
        """#.utf8))
        XCTAssertEqual(week.fraction, 2.0 / 3.0, accuracy: 0.001)

        // Going back to the newest title is an explicit null, not a missing key.
        let body = try JSONEncoder().encode(TitleChoice(slug: nil))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"slug":null}"#)
    }

    func testTheSummaryCarriesTheEntryTheWeekAndFirstMeetings() throws {
        let json = #"""
        {"entry": "4.2 km by bike, with 3 patches of new ground in it. The Fen Troll was seen off.",
         "weekNotice": {"week": "2026-W41", "kind": "OUTINGS", "title": "Three outings this week.", "target": 3, "unit": "outings",
                        "progress": 3, "done": true, "paid": true},
         "codexFirsts": [{"speciesId": "fen-troll", "name": "Fen Troll", "metAs": "Culvert Troll"}]}
        """#
        struct Part: Decodable { var entry: String?; var weekNotice: WeekNotice?; var codexFirsts: [CodexFirst]? }
        let part = try decoder.decode(Part.self, from: Data(json.utf8))
        XCTAssertEqual(part.weekNotice?.paid, true)
        XCTAssertEqual(part.codexFirsts?.first?.metAs, "Culvert Troll")
        XCTAssertNotNil(part.entry)
    }

    func testTheSheetSaysWhatDependsOnTheThingAndTheOuting() throws {
        let sheet = try decoder.decode(CharacterSheet.self, from: Data(#"""
        {"version": 2, "characterClass": "WARRIOR", "overallLevel": 12, "classLevel": 12, "damagePct": {"CLIMB": 0.4},
         "runeThreshold": 0.22, "runeReachMeters": 1000, "coinPct": {}, "xpPct": {"LONG_DISTANCE": 0.2},
         "vsEldersPct": 0.1, "lateRoadPct": 0.1, "lateRoadAfterMeters": 10000, "wordOldPlacesPct": 0}
        """#.utf8))
        XCTAssertEqual(sheet.pct(againstElder: false, madeGoodMeters: 3000, onFoot: false), ["CLIMB": 0.4])
        let elder = sheet.pct(againstElder: true, madeGoodMeters: 12_000, onFoot: false)
        XCTAssertEqual(elder["CLIMB"] ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(elder["ROAD"] ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(sheet.pct(againstElder: false, madeGoodMeters: 6000, onFoot: true)["ROAD"] ?? 0, 0.1, accuracy: 1e-9)
    }
}
