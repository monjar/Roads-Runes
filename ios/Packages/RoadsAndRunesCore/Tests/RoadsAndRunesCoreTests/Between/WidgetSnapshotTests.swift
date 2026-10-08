import Foundation
import XCTest
@testable import RoadsAndRunesCore

final class WidgetSnapshotTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "rr-widget-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func full() -> WidgetSnapshot {
        WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000.25), streakDays: 4, streakActiveToday: true,
            bounty: .init(name: "Fen Troll", icon: "troll", distanceMeters: 2_412.5, expiresAt: Date(timeIntervalSince1970: 1_790_100_000)),
            weekNotice: .init(title: "Three journeys this week", progress: 0.66, done: false),
            codexMet: 7, codexTotal: 24, level: 6, className: "Explorer",
            pledge: .init(targetName: "Fen Troll", icon: "troll"), units: .imperial
        )
    }

    func testRoundTripsThroughJSON() throws {
        let snapshot = full()
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), snapshot)
    }

    func testWritesAndReadsUnderItsKey() {
        XCTAssertNil(WidgetSnapshot.read(from: defaults))
        let snapshot = full()
        XCTAssertTrue(snapshot.write(to: defaults))
        XCTAssertNotNil(defaults.data(forKey: "widget.snapshot.v1"))
        XCTAssertEqual(WidgetSnapshot.read(from: defaults), snapshot)

        var next = snapshot
        next.streakDays = 5
        next.bounty = nil
        next.write(to: defaults)
        XCTAssertEqual(WidgetSnapshot.read(from: defaults)?.streakDays, 5)
        XCTAssertNil(WidgetSnapshot.read(from: defaults)?.bounty)

        WidgetSnapshot.clear(in: defaults)
        XCTAssertNil(WidgetSnapshot.read(from: defaults))
    }

    func testNowhereToWriteIsNotAnError() {
        XCTAssertFalse(full().write(to: nil))
        XCTAssertNil(WidgetSnapshot.read(from: nil))
    }

    func testTheAppGroupIsTheSharedOne() {
        XCTAssertEqual(WidgetSnapshot.appGroup, "group.com.roadsandrunes.app")
        XCTAssertEqual(WidgetSnapshot.defaultsKey, "widget.snapshot.v1")
    }

    /// A snapshot from a build that knew only the first fields still reads.
    func testAMinimalPayloadDecodes() throws {
        let json = #"{"updatedAt":780000000,"streakDays":2,"streakActiveToday":false}"#
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.streakDays, 2)
        XCTAssertNil(snapshot.bounty)
        XCTAssertNil(snapshot.units)
        XCTAssertEqual(snapshot.distance(1500), "1.5 km")
    }

    func testGarbageReadsAsNothing() {
        defaults.set(Data("not json".utf8), forKey: WidgetSnapshot.defaultsKey)
        XCTAssertNil(WidgetSnapshot.read(from: defaults))
    }

    func testTheBountyRunsOut() {
        let snapshot = full()
        XCTAssertTrue(snapshot.bountyIsLive(at: Date(timeIntervalSince1970: 1_790_050_000)))
        XCTAssertNil(snapshot.liveBounty(at: Date(timeIntervalSince1970: 1_790_100_001)))
        var open = snapshot
        open.bounty?.expiresAt = nil
        XCTAssertTrue(open.bountyIsLive(at: .distantFuture))
    }

    func testTheStreakLapsesAfterAMissedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        let wednesday = calendar.date(byAdding: .day, value: 2, to: monday)!

        let kept = WidgetSnapshot(updatedAt: monday, streakDays: 4, streakActiveToday: true)
        XCTAssertEqual(kept.streak(at: monday, calendar: calendar), 4)
        XCTAssertEqual(kept.streak(at: tuesday, calendar: calendar), 4)
        XCTAssertEqual(kept.streak(at: wednesday, calendar: calendar), 0)

        // Not yet kept on Monday: Monday's outing could still save it, Tuesday it is gone.
        let open = WidgetSnapshot(updatedAt: monday, streakDays: 4, streakActiveToday: false)
        XCTAssertEqual(open.streak(at: monday, calendar: calendar), 4)
        XCTAssertEqual(open.streak(at: tuesday, calendar: calendar), 0)
    }

    func testDistancesReadInThePlayersUnits() {
        XCTAssertEqual(full().distance(2_412.5), "1.5 mi")
        var metric = full()
        metric.units = .metric
        XCTAssertEqual(metric.distance(2_412.5), "2.4 km")
    }

    func testWeekProgressIsClamped() {
        XCTAssertEqual(WidgetSnapshot.WeekNotice(title: "x", progress: 1.4, done: true).progress, 1)
        XCTAssertEqual(WidgetSnapshot.WeekNotice(title: "x", progress: -1, done: false).progress, 0)
    }
}
