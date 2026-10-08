import XCTest
@testable import RoadsAndRunesCore

/// Between rides (0.7.3): pledges, letters and the sealed quest as the contract's
/// payloads have them, and every new field read from a server that never sent it.
final class BetweenDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: Data(json.utf8))
    }

    func testPledgeStateReadsTodayAndTomorrowEitherMissing() throws {
        let json = #"""
        {"today": {"day": "2026-10-05", "targetKind": "CREATURE", "targetId": "8a1f0b2c-0000-4000-8000-00000000a001",
                   "targetName": "Fen Troll", "icon": "troll", "remindAt": "18:00", "status": "PLEDGED"},
         "tomorrow": null}
        """#
        let state = try decode(PledgeState.self, json)
        XCTAssertEqual(state.today?.targetKind, .creature)
        XCTAssertEqual(state.today?.remindAt, "18:00")
        XCTAssertTrue(state.today?.isOpen ?? false)
        XCTAssertNil(state.tomorrow)
        XCTAssertEqual(state.open(for: UUID(uuidString: "8a1f0b2c-0000-4000-8000-00000000a001")!)?.targetName, "Fen Troll")

        let empty = try decode(PledgeState.self, "{}")
        XCTAssertNil(empty.today)
        XCTAssertNil(empty.tomorrow)
    }

    func testAPledgeWithoutIconOrReminderAndANewStatusStillReads() throws {
        let json = #"""
        {"day": "2026-10-06", "targetKind": "QUEST", "targetId": "44444444-4444-4444-8444-444444444444",
         "targetName": "Beyond the Water", "status": "SOMETHING_NEW"}
        """#
        let pledge = try decode(Pledge.self, json)
        XCTAssertEqual(pledge.targetKind, .quest)
        XCTAssertNil(pledge.icon)
        XCTAssertNil(pledge.remindAt)
        XCTAssertEqual(pledge.status, .unknown)
        XCTAssertFalse(pledge.isOpen)
    }

    func testThePledgeRequestSaysOnlyWhatIsAsked() throws {
        let body = try JSONCoding.encode(PledgeRequest(day: "2026-10-06", targetKind: .creature, targetId: SampleData.sampleMonster.id))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(object?["day"] as? String, "2026-10-06")
        XCTAssertEqual(object?["targetKind"] as? String, "CREATURE")
        XCTAssertNil(object?["remindAt"], "no reminder, no key")
    }

    func testLettersReadAsAListOrAPage() throws {
        let letter = #"""
        {"id": "1e77e400-0000-4000-8000-000000000073", "text": "The heron again.", "latitude": 51.49, "longitude": -0.04,
         "placeName": null, "writtenAt": "2026-07-01T08:00:00.123456Z", "shownAt": null}
        """#
        let list = try decode(LetterList.self, "[\(letter)]")
        XCTAssertEqual(list.letters.first?.text, "The heron again.")
        XCTAssertNil(list.letters.first?.placeName)
        XCTAssertNil(list.letters.first?.shownAt)
        let page = try decode(LetterList.self, #"{"items": [\#(letter)], "nextCursor": null}"#)
        XCTAssertEqual(page.letters.count, 1)
    }

    func testJourneysEndCarriesAKeptPledgeAndFoundLettersOnlyWhenSent() throws {
        var json = AdventureSummaryDecodingTests.json
        let plain = try decode(AdventureSummary.self, json)
        XCTAssertNil(plain.pledge, "an older server sends no pledge")
        XCTAssertNil(plain.letters)

        guard let brace = json.lastIndex(of: "}") else { return XCTFail("no summary") }
        json.replaceSubrange(brace...brace, with: #"""
        , "pledge": {"kept": true, "targetName": "Fen Troll", "line": "You said you would. You did."},
          "letters": [{"text": "The heron again.", "writtenAt": "2025-10-01T08:00:00Z", "placeName": "The Crown",
                       "line": "You wrote this here in October 2025."}]}
        """#)
        let summary = try decode(AdventureSummary.self, json)
        XCTAssertEqual(summary.pledge?.kept, true)
        XCTAssertEqual(summary.pledge?.shownLine, "You said you would. You did.")
        XCTAssertEqual(summary.letters?.first?.placeName, "The Crown")
        XCTAssertEqual(summary.letters?.first?.shownLine(), "You wrote this here in October 2025.")
    }

    func testTheServersSealedQuestAndSummaryShapesRead() throws {
        let quest = try XCTUnwrap(String(bytes: JSONCoding.encode(SampleData.sampleQuest), encoding: .utf8))
        let ordinary = try decode(Quest.self, quest.replacingOccurrences(of: #""title":"Beyond the Water""#, with: #""title":"Beyond the Water","extra":{}"#))
        XCTAssertEqual(ordinary.extra, [:])
        XCTAssertFalse(SealedQuest.isSealed(ordinary), "an empty extra is an ordinary quest")

        let goal = #"{"kind":"CREATURE","name":"Fen Troll","title":"Ride to the Fen Troll","latitude":51.5,"longitude":-0.03,"#
            + #""category":null,"discoveryId":null,"objectId":"8a1f0b2c-0000-4000-8000-00000000a001","icon":"troll"}"#
        let extra = #""title":"Sealed quest (40 min)","extra":{"sealed":true,"minutes":40,"revealAtFraction":0.5,"goal":"# + goal + "}"
        let sealed = try decode(Quest.self, quest.replacingOccurrences(of: #""title":"Beyond the Water""#, with: extra))
        XCTAssertEqual(SealedQuest.goal(of: sealed)?.title, "Ride to the Fen Troll")
        XCTAssertEqual(SealedQuest.goal(of: sealed)?.kind, "CREATURE")
        XCTAssertEqual(SealedQuest.goal(of: sealed)?.icon, "troll")
        XCTAssertEqual(SealedQuest.minutes(of: sealed), 40)

        let kept = try decode(PledgeKept.self, #"""
        {"kept": true, "day": "2026-10-05", "targetKind": "CREATURE", "targetId": "8a1f0b2c-0000-4000-8000-00000000a001",
         "targetName": "Fen Troll", "icon": "troll", "line": "You said you would. You did."}
        """#)
        XCTAssertEqual(kept.targetKind, .creature)
        XCTAssertEqual(kept.day, "2026-10-05")
        let found = try decode(FoundLetter.self, #"""
        {"id": "1e77e400-0000-4000-8000-000000000073", "text": "Hello", "writtenAt": "2025-10-01T08:00:00Z", "placeName": null,
         "latitude": 51.49, "longitude": -0.04, "line": "You wrote this here in October 2025."}
        """#)
        XCTAssertEqual(found.latitude, 51.49)
        XCTAssertNil(found.placeName)
    }

    func testAKeptPledgeWithoutALineSaysTheGlossarysOwn() {
        XCTAssertEqual(PledgeKept(kept: true, targetName: "Fen Troll").shownLine, "You said you would. You did.")
    }

    func testAFoundLetterWithoutALineSaysTheMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 12, day: 20))!
        let nextYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 20))!
        XCTAssertEqual(LetterRules.foundLine(writtenAt: october, now: later, calendar: calendar), "You wrote this here in October.")
        XCTAssertEqual(LetterRules.foundLine(writtenAt: october, now: nextYear, calendar: calendar), "You wrote this here in October 2026.")
        let found = FoundLetter(text: "Hello", writtenAt: october)
        XCTAssertEqual(found.shownLine(now: later, calendar: calendar), "You wrote this here in October.")
    }

    func testALetterIsTrimmedAndHeldTo140Characters() {
        XCTAssertEqual(LetterRules.cleaned("  Say hello to the heron.\n"), "Say hello to the heron.")
        XCTAssertNil(LetterRules.cleaned("   \n "))
        XCTAssertNotNil(LetterRules.cleaned(String(repeating: "a", count: 140)))
        XCTAssertNil(LetterRules.cleaned(String(repeating: "a", count: 141)))
    }

    func testASealedQuestReadsItsRevealFromTheQuestOrAnObjective() throws {
        var quest = SampleData.sampleQuest
        XCTAssertNil(SealedQuest.revealAtFraction(of: quest), "an ordinary quest is not sealed")
        XCTAssertNil(quest.extra, "an older server sends no extra")

        let json = try XCTUnwrap(String(bytes: JSONCoding.encode(quest), encoding: .utf8))
            .replacingOccurrences(of: #""title":"Beyond the Water""#, with: #""title":"Sealed quest (40 min)","extra":{"revealAtFraction":0.5}"#)
        let sealed = try decode(Quest.self, json)
        XCTAssertEqual(sealed.title, "Sealed quest (40 min)")
        XCTAssertEqual(SealedQuest.revealAtFraction(of: sealed), 0.5)

        quest.objectives[0].extra = ["revealAtFraction": .number(0.6)]
        XCTAssertEqual(SealedQuest.revealAtFraction(of: quest), 0.6, "on an objective it counts too")

        var typed = SampleData.sampleQuest
        typed.questType = "SEALED"
        XCTAssertEqual(SealedQuest.revealAtFraction(of: typed), 0.5, "typed SEALED without a number opens halfway")
    }

    func testTheEndpointsAreTheContracts() throws {
        XCTAssertEqual(Endpoints.pledges(today: "2026-10-05").path, "/pledge")
        XCTAssertEqual(Endpoints.pledges(today: "2026-10-05").query, [QueryItem("today", "2026-10-05")])
        let put = try Endpoints.pledge(PledgeRequest(day: "2026-10-06", targetKind: .quest, targetId: SampleData.questId, remindAt: "07:30"))
        XCTAssertEqual(put.method, .put)
        XCTAssertEqual(put.path, "/pledge")
        XCTAssertEqual(Endpoints.cancelPledge(day: "2026-10-06").path, "/pledge/2026-10-06")
        XCTAssertEqual(Endpoints.cancelPledge(day: "2026-10-06").method, .delete)
        XCTAssertEqual(Endpoints.letters().path, "/letters")
        let write = try Endpoints.writeLetter(LetterCreate(latitude: 51.5, longitude: -0.1, text: "Hi"))
        XCTAssertEqual(write.method, .post)
        XCTAssertEqual(write.path, "/letters")
        XCTAssertEqual(Endpoints.deleteLetter(id: SampleData.letterId).path, "/letters/\(SampleData.letterId.uuidString)")
        let sealed = try Endpoints.sealedQuest(SealedQuestRequest(minutes: 40, latitude: 51.5, longitude: -0.1, activity: .run))
        XCTAssertEqual(sealed.method, .post)
        XCTAssertEqual(sealed.path, "/quests/sealed")
        let body = try JSONSerialization.jsonObject(with: sealed.body ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["minutes"] as? Int, 40)
        XCTAssertEqual(body?["activity"] as? String, "RUN")
    }
}
