import XCTest
@testable import RoadsAndRunesCore

/// The pure rules of 0.7.3: when a pledge can be made, when a sealed quest's goal
/// opens, how a shared trace is masked, and the savings goals kept on the phone.
final class BetweenRulesTests: XCTestCase {
    private var london: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 5, month: Int = 10) -> Date {
        london.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Pledge windows

    func testTheMorningPledgesForTodayAndTheEveningForTomorrow() {
        XCTAssertEqual(PledgeWindow.current(at: at(6), calendar: london), .today)
        XCTAssertEqual(PledgeWindow.current(at: at(11, 59), calendar: london), .today)
        XCTAssertNil(PledgeWindow.current(at: at(12), calendar: london), "the afternoon offers neither")
        XCTAssertNil(PledgeWindow.current(at: at(16, 59), calendar: london))
        XCTAssertEqual(PledgeWindow.current(at: at(17), calendar: london), .tomorrow)
        XCTAssertEqual(PledgeWindow.current(at: at(23, 50), calendar: london), .tomorrow)
        XCTAssertEqual(PledgeWindow.today.buttonTitle, "Pledge for today")
        XCTAssertEqual(PledgeWindow.tomorrow.buttonTitle, "Pledge for tomorrow")
    }

    func testThePledgedDayIsThePhonesOwnDate() {
        XCTAssertEqual(PledgeWindow.today.day(from: at(8), calendar: london), "2026-10-05")
        XCTAssertEqual(PledgeWindow.tomorrow.day(from: at(21), calendar: london), "2026-10-06")
        // Late on the last of the month, tomorrow is the first of the next.
        XCTAssertEqual(PledgeWindow.tomorrow.day(from: at(23, 30, day: 31, month: 10), calendar: london), "2026-11-01")
        // 00:30 in London is still the day before in UTC; the phone's day is what counts.
        XCTAssertEqual(PledgeWindow.today.day(from: at(0, 30, day: 6), calendar: london), "2026-10-06")
    }

    func testTheReminderGoesOffOnThePledgedDayOnlyIfStillToCome() {
        let reminder = PledgeWindow.reminderDate(day: "2026-10-06", remindAt: "07:45", now: at(21), calendar: london)
        XCTAssertEqual(reminder, london.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 7, minute: 45)))
        XCTAssertNil(PledgeWindow.reminderDate(day: "2026-10-05", remindAt: "07:45", now: at(9), calendar: london), "already past")
        XCTAssertNil(PledgeWindow.reminderDate(day: "2026-10-06", remindAt: "25:00", now: at(9), calendar: london))
        XCTAssertNil(PledgeWindow.reminderDate(day: "not a day", remindAt: "07:45", now: at(9), calendar: london))
        XCTAssertEqual(PledgeWindow.timeString(at(7, 5), calendar: london), "07:05")
    }

    // MARK: Sealed quest

    func testTheGoalOpensAtTheRevealFractionAndNotBefore() {
        let quest = SampleData.sealedQuest(minutes: 40, origin: SampleData.origin)
        XCTAssertTrue(SealedQuest.isSealed(quest))
        XCTAssertFalse(SealedQuest.isOpen(quest, routeFraction: nil), "no route progress yet")
        XCTAssertFalse(SealedQuest.isOpen(quest, routeFraction: 0.49))
        XCTAssertTrue(SealedQuest.isOpen(quest, routeFraction: 0.5))
        XCTAssertTrue(SealedQuest.isOpen(quest, routeFraction: 0.8))
    }

    func testOnTheRideTheOpenGoalIsReadOnlyAtAStandstill() {
        let quest = SampleData.sealedQuest(minutes: 20, origin: SampleData.origin)
        XCTAssertFalse(SealedQuest.showsGoalWhileRiding(quest, routeFraction: 0.7, isStill: false), "moving: nothing to read")
        XCTAssertTrue(SealedQuest.showsGoalWhileRiding(quest, routeFraction: 0.7, isStill: true))
        XCTAssertFalse(SealedQuest.showsGoalWhileRiding(quest, routeFraction: 0.2, isStill: true), "still, but not halfway")
        XCTAssertTrue(SealedQuest.showsGoalWhileRiding(SampleData.sampleQuest, routeFraction: nil, isStill: false), "an ordinary quest is never hidden")
    }

    func testTheGoalIsTheServersOwnWordsKeptOnTheQuest() {
        let quest = SampleData.sealedQuest(minutes: 40, origin: SampleData.origin, activity: .run)
        XCTAssertEqual(SealedQuest.revealAtFraction(of: quest), 0.5, "read from the quest's extra, as the server puts it")
        XCTAssertEqual(SealedQuest.minutes(of: quest), 40)
        XCTAssertEqual(quest.objectives.first?.title, "Reach the goal", "the hidden objective says nothing")
        let goal = SealedQuest.goal(of: quest)
        XCTAssertEqual(goal?.title, "Run to The Crown")
        XCTAssertEqual(goal?.name, "The Crown")
        XCTAssertEqual(goal?.kind, "PLACE")
        XCTAssertNotNil(goal?.coordinate)
        XCTAssertNil(quest.objectives.first?.coordinate, "the objective itself has no place")
        XCTAssertNil(SealedQuest.goal(of: SampleData.sampleQuest), "an ordinary quest has no sealed goal")

        // An older shape with the goal on the objective still reads.
        var onObjective = SampleData.sampleQuest
        onObjective.objectives[0].extra = ["revealAtFraction": .number(0.5), "goal": .object(["title": .string("Walk to the Mill")])]
        XCTAssertEqual(SealedQuest.goal(of: onObjective)?.title, "Walk to the Mill")
    }

    func testADoneGoalIsOpenWhereverTheRiderIs() {
        var quest = SampleData.sealedQuest(minutes: 90, origin: SampleData.origin)
        quest.objectives[0].status = .completed
        XCTAssertTrue(SealedQuest.isOpen(quest, routeFraction: 0.1))
        var finished = SampleData.sealedQuest(minutes: 90, origin: SampleData.origin)
        finished.status = .completed
        XCTAssertTrue(SealedQuest.isOpen(finished, routeFraction: nil), "Journey's end names it")
        XCTAssertEqual(SealedQuest.minutes(of: finished), 90)
    }

    // MARK: Trace mask

    /// A straight line north, `meters` long, a fix every `step` metres.
    private func line(meters: Double, step: Double = 100) -> [Coordinate] {
        stride(from: 0.0, through: meters, by: step).map {
            GeoMath.destination(from: SampleData.origin, bearingDegrees: 0, distanceMeters: $0)
        }
    }

    func testTheFirstAndLastKilometreAreCut() {
        let trace = line(meters: 5000)
        let masked = TraceMask.masked(trace, trimMeters: 1000)
        XCTAssertEqual(GeoMath.pathLength(masked), 3000, accuracy: 1)
        XCTAssertEqual(GeoMath.distance(trace[0], masked[0]), 1000, accuracy: 1, "starts a kilometre in")
        XCTAssertEqual(GeoMath.distance(trace[trace.count - 1], masked[masked.count - 1]), 1000, accuracy: 1, "ends a kilometre short")
        for point in masked {
            XCTAssertGreaterThanOrEqual(GeoMath.distance(trace[0], point), 999, "nothing within a kilometre of the start")
            XCTAssertGreaterThanOrEqual(GeoMath.distance(trace[trace.count - 1], point), 999, "nor of the end")
        }
    }

    func testTheCutFallsBetweenFixesExactly() {
        let sparse = [0.0, 1500, 2500, 4000].map { GeoMath.destination(from: SampleData.origin, bearingDegrees: 0, distanceMeters: $0) }
        let masked = TraceMask.masked(sparse, trimMeters: 1000)
        XCTAssertEqual(GeoMath.pathLength(masked), 2000, accuracy: 1)
        XCTAssertEqual(masked.count, 4, "the two cuts and the two fixes between them")
    }

    func testAShortTraceIsAllHomeAndCannotBeShared() {
        XCTAssertTrue(TraceMask.masked(line(meters: 2000), trimMeters: 1000).isEmpty, "two kilometres is nothing once both ends go")
        XCTAssertTrue(TraceMask.masked([SampleData.origin], trimMeters: 1000).isEmpty)
        XCTAssertFalse(TraceMask.canShare(line(meters: 2400)))
        XCTAssertNil(TraceMask.shareable(line(meters: 2400)), "under 2.5 km: too short to share safely")
        XCTAssertTrue(TraceMask.canShare(line(meters: 2600)))
        XCTAssertEqual(GeoMath.pathLength(TraceMask.shareable(line(meters: 2600)) ?? []), 600, accuracy: 1)
        XCTAssertEqual(TraceMask.tooShortLine, "Too short to share safely.")
    }

    // MARK: Savings goals

    private func freshDefaults() -> UserDefaults {
        let name = "rr.savings.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testASavingsGoalIsKeptAndShowsAgainstThePurse() {
        let store = SavingsGoalStore(defaults: freshDefaults())
        XCTAssertTrue(store.load().isEmpty)
        let tape = store.add(name: "  New bar tape ", coins: 5000)
        XCTAssertEqual(tape?.name, "New bar tape")
        store.add(name: "Rain jacket", coins: 12_000)
        XCTAssertEqual(store.load().map(\.name), ["New bar tape", "Rain jacket"], "oldest first")
        XCTAssertEqual(tape?.fraction(purse: 1250) ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(tape?.fraction(purse: 9000), 1)
        XCTAssertEqual(tape?.isReached(purse: 5000), true)
        XCTAssertEqual(tape?.isReached(purse: 4999), false)
    }

    func testAGoalWithoutANameOrCoinsIsNotKeptAndOneCanBeRemoved() throws {
        let store = SavingsGoalStore(defaults: freshDefaults())
        XCTAssertNil(store.add(name: "   ", coins: 500))
        XCTAssertNil(store.add(name: "Tyres", coins: 0))
        XCTAssertNil(store.add(name: "Tyres", coins: SavingsGoal.maxCoins + 1))
        XCTAssertTrue(store.load().isEmpty)
        let tyres = try XCTUnwrap(store.add(name: "Tyres", coins: 800))
        store.add(name: "Lights", coins: 300)
        store.remove(id: tyres.id)
        XCTAssertEqual(store.load().map(\.name), ["Lights"])
        XCTAssertEqual(SavingsGoal.make(name: String(repeating: "x", count: 60), coins: 10)?.name.count, SavingsGoal.maxNameLength)
    }

    func testWithoutTheAppGroupNothingIsKeptAndNothingBreaks() {
        let store = SavingsGoalStore(defaults: nil)
        XCTAssertNotNil(store.add(name: "Tyres", coins: 800), "the goal is made")
        XCTAssertTrue(store.load().isEmpty, "but there is nowhere to keep it")
    }
}
