import XCTest
@testable import RoadsAndRunesCore

/// The mock keeps the server's rules for pledges, letters and the sealed quest
/// (0.7.3), so previews and the app's tests meet the same answers.
final class MockAPIBetweenTests: XCTestCase {
    private func error(of call: () async throws -> some Any) async -> APIError? {
        do {
            _ = try await call()
            return nil
        } catch let error as APIError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: Pledge

    func testAPledgeIsOneADayAndASecondReplacesIt() async throws {
        let api = MockAPI()
        let creature = try await api.pledge(PledgeRequest(day: "2026-10-06", targetKind: .creature, targetId: SampleData.sampleMonster.id, remindAt: "07:30"))
        XCTAssertEqual(creature.targetName, SampleData.sampleMonster.name)
        XCTAssertEqual(creature.status, .pledged)
        var state = try await api.pledges(today: "2026-10-05")
        XCTAssertNil(state.today)
        XCTAssertEqual(state.tomorrow?.targetId, SampleData.sampleMonster.id)

        _ = try await api.pledge(PledgeRequest(day: "2026-10-06", targetKind: .quest, targetId: SampleData.questId))
        state = try await api.pledges(today: "2026-10-05")
        XCTAssertEqual(state.tomorrow?.targetKind, .quest, "the same day's pledge is replaced")
        XCTAssertEqual(state.tomorrow?.targetName, SampleData.sampleQuest.title)

        try await api.cancelPledge(day: "2026-10-06")
        state = try await api.pledges(today: "2026-10-05")
        XCTAssertNil(state.tomorrow)
        let again = await error { try await api.cancelPledge(day: "2026-10-06") }
        XCTAssertEqual(again?.errorCode, APIErrorCode.notFound)
    }

    func testAPledgeForSomethingGoneIsRefusedInPlainWords() async {
        let api = MockAPI()
        let gone = await error { try await api.pledge(PledgeRequest(day: "2026-10-06", targetKind: .creature, targetId: UUID())) }
        XCTAssertEqual(gone?.errorCode, APIErrorCode.notFound)
        XCTAssertEqual(gone?.errorDescription, "That creature or quest isn't on your map any more. Pick another.")
        let chest = await error { try await api.pledge(PledgeRequest(day: "2026-10-06", targetKind: .creature, targetId: SampleData.sampleChest.id)) }
        XCTAssertEqual(chest?.errorCode, APIErrorCode.notFound, "a chest is not a creature")
        let badTime = await error {
            try await api.pledge(PledgeRequest(day: "2026-10-06", targetKind: .creature, targetId: SampleData.sampleMonster.id, remindAt: "late"))
        }
        XCTAssertEqual(badTime?.errorCode, APIErrorCode.validationError)
    }

    func testAMissedPledgeIsNeverSentAgain() async throws {
        let api = MockAPI()
        _ = try await api.pledge(PledgeRequest(day: "2026-10-05", targetKind: .creature, targetId: SampleData.sampleMonster.id))
        let same = try await api.pledges(today: "2026-10-05")
        XCTAssertEqual(same.today?.status, .pledged)
        let nextDay = try await api.pledges(today: "2026-10-06")
        XCTAssertNil(nextDay.today, "yesterday's is not today's")
        XCTAssertNil(nextDay.tomorrow)
    }

    func testAJourneyThatDefeatsThePledgedCreatureKeepsIt() async throws {
        let api = MockAPI()
        _ = try await api.pledge(PledgeRequest(day: "2026-10-05", targetKind: .creature, targetId: SampleData.sampleMonster.id))
        XCTAssertNil(api.keepPledge(day: "2026-10-05", defeated: UUID()), "something else defeated keeps nothing")
        let kept = api.keepPledge(day: "2026-10-05", defeated: SampleData.sampleMonster.id)
        XCTAssertEqual(kept?.line, "You said you would. You did.")
        let state = try await api.pledges(today: "2026-10-05")
        XCTAssertEqual(state.today?.status, .kept)
        XCTAssertNil(api.keepPledge(day: "2026-10-05", defeated: SampleData.sampleMonster.id), "kept once")
    }

    func testDaysRollOverMonthsAndYears() {
        XCTAssertEqual(MockAPI.dayAfter("2026-10-31"), "2026-11-01")
        XCTAssertEqual(MockAPI.dayAfter("2026-12-31"), "2027-01-01")
        XCTAssertNil(MockAPI.dayAfter("2026-13-01"))
    }

    // MARK: Letters

    func testALetterIsWrittenNamedByTheNearestPlaceAndListedNewestFirst() async throws {
        let api = MockAPI()
        // The Crown is at 51.4915, -0.0365: this is about 30 m from it.
        let near = try await api.writeLetter(LetterCreate(latitude: 51.4917, longitude: -0.0367, text: "  The heron again.  "))
        XCTAssertEqual(near.text, "The heron again.")
        XCTAssertEqual(near.placeName, "The Crown")
        let far = try await api.writeLetter(LetterCreate(latitude: 51.40, longitude: -0.20, text: "Nowhere in particular."))
        XCTAssertNil(far.placeName, "no named place within 80 m")
        api.store(letter: SampleData.sampleLetter)
        let all = try await api.letters()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.last?.id, SampleData.letterId, "the oldest last")

        try await api.deleteLetter(id: near.id)
        let left = try await api.letters()
        XCTAssertEqual(left.count, 2)
        let missing = await error { try await api.deleteLetter(id: near.id) }
        XCTAssertEqual(missing?.errorCode, APIErrorCode.notFound)
    }

    func testAnEmptyOrLongLetterIsRefused() async {
        let api = MockAPI()
        let empty = await error { try await api.writeLetter(LetterCreate(latitude: 51.49, longitude: -0.04, text: "   ")) }
        XCTAssertEqual(empty?.errorCode, APIErrorCode.validationError)
        let long = await error { try await api.writeLetter(LetterCreate(latitude: 51.49, longitude: -0.04, text: String(repeating: "a", count: 141))) }
        XCTAssertEqual(long?.errorCode, APIErrorCode.validationError)
    }

    func testAnOldLetterNearTheTraceIsFoundOnceAndANewOneWaits() async throws {
        let api = MockAPI()
        let now = Date()
        api.store(letter: Letter(id: UUID(), text: "Old", latitude: 51.4915, longitude: -0.0365, writtenAt: now.addingTimeInterval(-100 * 86_400)))
        api.store(letter: Letter(id: UUID(), text: "New", latitude: 51.4915, longitude: -0.0365, writtenAt: now.addingTimeInterval(-10 * 86_400)))
        api.store(letter: Letter(id: UUID(), text: "Far", latitude: 51.40, longitude: -0.20, writtenAt: now.addingTimeInterval(-200 * 86_400)))
        let trace = [Coordinate(latitude: 51.4913, longitude: -0.0365), Coordinate(latitude: 51.4950, longitude: -0.0300)]
        let found = api.findLetters(along: trace, at: now)
        XCTAssertEqual(found.map(\.text), ["Old"])
        XCTAssertTrue(found.first?.line?.hasPrefix("You wrote this here in") ?? false)
        XCTAssertTrue(api.findLetters(along: trace, at: now).isEmpty, "found once")
        let shelf = try await api.letters()
        XCTAssertNotNil(shelf.first { $0.text == "Old" }?.shownAt)
    }

    // MARK: Sealed quest

    func testASealedQuestComesAcceptedWithItsGoalHiddenAndARoute() async throws {
        let api = MockAPI()
        let quest = try await api.sealedQuest(SealedQuestRequest(minutes: 40, at: SampleData.origin, activity: .run))
        XCTAssertEqual(quest.status, .accepted)
        XCTAssertEqual(quest.title, "Sealed quest (40 min)")
        XCTAssertEqual(quest.description, "The board picked the way. Your goal opens halfway.")
        XCTAssertEqual(SealedQuest.revealAtFraction(of: quest), 0.5)
        XCTAssertEqual(quest.activity, .run)
        XCTAssertNil(quest.objectives.first?.coordinate, "the goal's place is held back")
        let routeId = try XCTUnwrap(quest.suggestedRouteId)
        let package = try await api.routePackage(id: routeId)
        XCTAssertFalse(package.route.path.isEmpty)
        let route = try await api.questRoute(id: quest.id, from: SampleData.origin)
        XCTAssertEqual(route.id, routeId, "the quest's own route")
    }

    func testOnlyTheOfferedLengthsAndOneSealedQuestAtATime() async throws {
        let api = MockAPI()
        let odd = await error { try await api.sealedQuest(SealedQuestRequest(minutes: 45, at: SampleData.origin)) }
        XCTAssertEqual(odd?.errorCode, APIErrorCode.validationError)
        let first = try await api.sealedQuest(SealedQuestRequest(minutes: 20, at: SampleData.origin))
        let second = try await api.sealedQuest(SealedQuestRequest(minutes: 90, at: SampleData.origin))
        let firstNow = try await api.quest(id: first.id)
        XCTAssertEqual(firstNow.status, .abandoned, "a second replaces the first not yet started")
        XCTAssertEqual(second.difficulty, .moderate, "ninety minutes pays like a medium quest")
    }
}
