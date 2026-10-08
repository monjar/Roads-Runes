import XCTest
@testable import RoadsAndRunesCore

/// Between rides on the wrist (0.7.3): starting a journey from the Watch, Next up
/// on its idle screen, and what its complication says.
final class WatchBetweenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let here = Coordinate(latitude: 51.5, longitude: -0.1)
    private let questId = UUID(uuidString: "4A1F0B2C-0000-4000-8000-0000000000A1")!

    // MARK: Start requests

    func testAStartRequestRoundTripsUnderItsOwnKind() throws {
        let request = WatchStartRequest(kind: WatchStartRequest.loop, minutes: 40, activity: "RUN", requestedAt: now)
        let message = try WatchMessages.startRequest(request)
        XCTAssertEqual(WatchMessages.kind(of: message), .startRequest)
        XCTAssertEqual(try WatchMessages.startRequest(from: message), request)
        XCTAssertThrowsError(try WatchMessages.command(from: message), "a start request is not a command")

        let result = WatchStartResult(requestId: request.id, started: false)
        let answer = try WatchMessages.startResult(result)
        XCTAssertEqual(WatchMessages.kind(of: answer), .startResult)
        XCTAssertEqual(try WatchMessages.startResult(from: answer), result)
    }

    func testAStartRequestBecomesTheQuickStartThePhonePlans() {
        let loop = WatchStartRequest.loop(minutes: 20, activity: .run)
        XCTAssertEqual(loop.quickStart(defaultActivity: .ride), .loop(minutes: 20, activity: .run))
        // No activity asked for: the phone's own; a loop with no minutes lasts 40.
        let plain = WatchStartRequest(kind: "LOOP")
        XCTAssertEqual(plain.quickStart(defaultActivity: .walk), .loop(minutes: 40, activity: .walk))
        XCTAssertEqual(WatchStartRequest(kind: "loop", activity: "SKATE").quickStart(defaultActivity: .unknown),
                       .loop(minutes: 40, activity: .ride), "an activity nobody knows rides")

        XCTAssertEqual(WatchStartRequest.bounty(activity: .ride).quickStart(defaultActivity: .ride), .bounty)
        XCTAssertEqual(WatchStartRequest.quest(id: questId).quickStart(defaultActivity: .ride), .quest(id: questId))
        XCTAssertNil(WatchStartRequest(kind: "QUEST").quickStart(defaultActivity: .ride), "a quest needs its id")
        XCTAssertEqual(WatchStartRequest.sealed(minutes: 45).quickStart(defaultActivity: .ride), .sealed(minutes: 40))
        XCTAssertNil(WatchStartRequest(kind: "TELEPORT").quickStart(defaultActivity: .ride))
    }

    func testARequestHeardTooLateStartsNothing() {
        let asked = WatchStartRequest.loop(minutes: 40, activity: .ride)
        var late = asked
        late.requestedAt = now
        XCTAssertNotNil(late.quickStart(defaultActivity: .ride, at: now.addingTimeInterval(WatchStartRequest.keptFor - 1)))
        XCTAssertNil(late.quickStart(defaultActivity: .ride, at: now.addingTimeInterval(WatchStartRequest.keptFor + 1)))
        late.requestedAt = nil
        XCTAssertNotNil(late.quickStart(defaultActivity: .ride, at: now), "with no time it came straight from the wrist")
    }

    // MARK: The application context

    func testNextUpTravelsBesideTheRideAndNeitherPushesTheOtherOut() throws {
        let idle = WatchIdleInfo(streakDays: 4, streakActiveToday: true, bounty: .init(name: "Fen Troll", icon: "troll"),
                                 activity: "RIDE", updatedAt: now)
        let update = WatchNavigationUpdate(state: .active, distanceMeters: 4000, elapsedSeconds: 900, elevationGainMeters: 40,
                                           timestamp: now)
        let context = try WatchMessages.context(ride: WatchMessages.navigationUpdate(update), idle: idle)
        XCTAssertEqual(WatchMessages.kind(of: context), .navigationUpdate)
        XCTAssertEqual(try WatchMessages.navigationUpdate(from: context).distanceMeters, 4000)
        XCTAssertEqual(WatchMessages.idleInfo(from: context), idle)

        // Between rides the context is Next up alone, which an older Watch cannot name.
        let alone = try WatchMessages.context(ride: nil, idle: idle)
        XCTAssertNil(WatchMessages.kind(of: alone))
        XCTAssertEqual(WatchMessages.idleInfo(from: alone), idle)
        XCTAssertNil(WatchMessages.idleInfo(from: try WatchMessages.navigationUpdate(update)))
        XCTAssertNil(try WatchMessages.context(ride: context, idle: nil)[WatchMessageKind.idleInfoKey])
    }

    /// Before 0.7.3: no start request, no start result.
    private enum OldKind: String {
        case routeSummary, navigationUpdate, objectiveCompleted, command, heartRate, encounterBeat, journeyEnd
    }

    func testAnOlderPhoneOrWatchCannotNameTheNewKindsAndLetsThemGo() throws {
        for message in [try WatchMessages.startRequest(.bounty(activity: nil)),
                        try WatchMessages.startResult(WatchStartResult(requestId: nil, started: false))] {
            let raw = try XCTUnwrap(message[WatchMessageKind.kindKey] as? String)
            XCTAssertNil(OldKind(rawValue: raw))
        }
    }

    func testAnyPhonesNextUpIsRead() throws {
        // Fields a phone does not send are nothing; fields a newer phone adds are passed over.
        let bare = try JSONCoding.decode(WatchIdleInfo.self, from: Data("{}".utf8))
        XCTAssertEqual(bare.streakDays, 0)
        XCTAssertFalse(bare.streakActiveToday)
        XCTAssertTrue(bare.quests.isEmpty)
        XCTAssertNil(bare.bounty)
        let newer = Data(#"{"streakDays":3,"quests":[{"id":"\#(questId.uuidString)","title":"Beyond the Water","colour":"red"}],"weather":"rain"}"#.utf8)
        let read = try JSONCoding.decode(WatchIdleInfo.self, from: newer)
        XCTAssertEqual(read.streakDays, 3)
        XCTAssertEqual(read.quests.map(\.title), ["Beyond the Water"])
        // And the start request reads the same way.
        let request = try JSONCoding.decode(WatchStartRequest.self, from: Data(#"{"id":"\#(questId.uuidString)","kind":"BOUNTY","why":"x"}"#.utf8))
        XCTAssertEqual(request.quickStart(defaultActivity: .ride), .bounty)
    }

    // MARK: Next up, made on the phone

    private func creature(_ name: String, meters: Double, bounty: Bool = true, expires: TimeInterval = 3600,
                          status: WorldObjectStatus = .spawned) -> WorldObject {
        let at = GeoMath.destination(from: here, bearingDegrees: 90, distanceMeters: meters)
        return WorldObject(id: UUID(), kind: .monster, status: status, latitude: at.latitude, longitude: at.longitude, name: name,
                           bounty: bounty, rewardAC: 40, expiresAt: now.addingTimeInterval(expires))
    }

    private func quest(_ title: String, status: QuestStatus, objectiveMeters: Double? = 800, expires: Date? = nil) -> Quest {
        var quest = SampleData.sampleQuest
        quest.id = UUID()
        quest.title = title
        quest.status = status
        quest.expiresAt = expires
        let at = objectiveMeters.map { GeoMath.destination(from: here, bearingDegrees: 0, distanceMeters: $0) }
        quest.objectives = [
            Objective(id: UUID(), objectiveType: .visitLocation, title: "Reach it", latitude: at?.latitude, longitude: at?.longitude,
                      required: true, order: 1, progress: ObjectiveProgress(current: 0, target: 1)),
        ]
        return quest
    }

    func testNextUpIsMadeFromWhatThePhoneHasLoaded() throws {
        var character = SampleData.sampleCharacter
        character.streakDays = 6
        character.streakActiveToday = true
        let objects = [
            creature("Far Troll", meters: 4000),
            creature("Fen Troll", meters: 900),
            creature("Gone Troll", meters: 100, expires: -60),
            creature("Grey Stag", meters: 50, bounty: false),
        ]
        let quests = [
            quest("Waiting", status: .accepted),
            quest("Not taken", status: .available),
            quest("Under way", status: .active, objectiveMeters: 1200),
            quest("Run out", status: .accepted, expires: now.addingTimeInterval(-1)),
            quest("Second", status: .accepted, objectiveMeters: nil),
            quest("Third", status: .accepted),
        ]
        let info = WatchIdleInfo.make(
            character: character, objects: objects, quests: quests, position: here, activity: .run, units: .imperial, now: now,
            icon: { _ in "troll" }, questIcon: { _ in "compass" }
        )
        XCTAssertEqual(info.streakDays, 6)
        XCTAssertTrue(info.streakActiveToday)
        let bounty = try XCTUnwrap(info.bounty)
        XCTAssertEqual(bounty.name, "Fen Troll", "the nearest bounty still out")
        XCTAssertEqual(bounty.icon, "troll")
        XCTAssertEqual(try XCTUnwrap(bounty.distanceMeters), 900, accuracy: 5)
        XCTAssertEqual(info.quests.map(\.title), ["Under way", "Waiting", "Second"], "under way first, then taken, three at most")
        XCTAssertEqual(try XCTUnwrap(info.quests.first?.distanceMeters), 1200, accuracy: 5)
        XCTAssertNil(info.quests[2].distanceMeters, "no place to go, no distance")
        XCTAssertEqual(info.quests.first?.icon, "compass")
        XCTAssertEqual(info.activity, "RUN")
        XCTAssertEqual(info.units, "IMPERIAL")
        XCTAssertEqual(info.updatedAt, now)

        let nothing = WatchIdleInfo.make(character: nil, objects: [], quests: [], position: nil, activity: .unknown, units: .unknown, now: now)
        XCTAssertEqual(nothing.streakDays, 0)
        XCTAssertNil(nothing.bounty)
        XCTAssertNil(nothing.activity)
        XCTAssertNil(nothing.units)
    }

    func testTheStreakLapsesTheDayAfterADayNotKept() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let day = { (n: Int) in calendar.date(byAdding: .day, value: n, to: morning)! }
        let kept = WatchIdleInfo(streakDays: 5, streakActiveToday: true, updatedAt: morning)
        XCTAssertEqual(kept.streak(at: morning, calendar: calendar), 5)
        XCTAssertTrue(kept.streakKept(at: morning, calendar: calendar))
        XCTAssertEqual(kept.streak(at: day(1), calendar: calendar), 5, "kept yesterday: still alive today")
        XCTAssertFalse(kept.streakKept(at: day(1), calendar: calendar))
        XCTAssertEqual(kept.streak(at: day(2), calendar: calendar), 0)
        let notYet = WatchIdleInfo(streakDays: 5, streakActiveToday: false, updatedAt: morning)
        XCTAssertEqual(notYet.streak(at: morning, calendar: calendar), 5)
        XCTAssertEqual(notYet.streak(at: day(1), calendar: calendar), 0)
    }

    func testTheSameNextUpFromTheSameDayIsNotSentTwice() {
        let first = WatchIdleInfo(streakDays: 2, bounty: .init(name: "Fen Troll"), updatedAt: now)
        var later = first
        later.updatedAt = now.addingTimeInterval(60)
        XCTAssertTrue(later.says(sameAs: first))
        var changed = later
        changed.streakDays = 3
        XCTAssertFalse(changed.says(sameAs: first))
        var tomorrow = first
        tomorrow.updatedAt = now.addingTimeInterval(86_400 * 1.5)
        XCTAssertFalse(tomorrow.says(sameAs: first), "a new day can change the streak")
        XCTAssertFalse(first.says(sameAs: nil))
    }

    // MARK: Kept on the Watch

    func testTheIdleStoreKeepsNextUpAndTheQuarryAndSaysWhenItChanged() throws {
        let suite = "rr.tests.watch-idle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(WatchIdleStore.readIdle(from: defaults))
        let idle = WatchIdleInfo(streakDays: 4, bounty: .init(name: "Fen Troll", icon: "troll", distanceMeters: 2400), updatedAt: now)
        XCTAssertTrue(WatchIdleStore.write(idle: idle, to: defaults))
        XCTAssertFalse(WatchIdleStore.write(idle: idle, to: defaults), "the same again is no news")
        XCTAssertEqual(WatchIdleStore.readIdle(from: defaults), idle)

        let quarry = WatchQuarry(mark: WatchWorldMark(id: UUID(), kind: WatchWorldMark.monster, name: "Bog Wraith", latitude: 51.5,
                                                      longitude: -0.1, icon: "ghost", speciesId: "bog-wraith", quarry: true))
        XCTAssertTrue(WatchIdleStore.write(quarry: quarry, to: defaults))
        XCTAssertEqual(WatchIdleStore.readQuarry(from: defaults), quarry)
        XCTAssertTrue(WatchIdleStore.write(quarry: nil, to: defaults))
        XCTAssertFalse(WatchIdleStore.write(quarry: nil, to: defaults))
        XCTAssertNil(WatchIdleStore.readQuarry(from: defaults))
        XCTAssertFalse(WatchIdleStore.write(idle: idle, to: nil), "nowhere to write")
    }

    // MARK: The complication

    func testTheComplicationShowsTheQuarryElseTheBountyElseTheStreak() {
        let idle = WatchIdleInfo(streakDays: 4, streakActiveToday: true,
                                 bounty: .init(name: "Fen Troll", icon: "troll", speciesId: "fen-troll", distanceMeters: 2400,
                                               expiresAt: now.addingTimeInterval(3600)),
                                 units: "METRIC", updatedAt: now)
        let riding = WatchComplication(idle: idle, quarry: WatchQuarry(name: "Bog Wraith", icon: "ghost"), at: now)
        XCTAssertEqual(riding.mark, .quarry(name: "Bog Wraith", icon: "ghost", speciesId: nil))
        XCTAssertTrue(riding.mark?.isQuarry ?? false)

        let between = WatchComplication(idle: idle, quarry: nil, at: now)
        XCTAssertEqual(between.mark?.name, "Fen Troll")
        XCTAssertEqual(between.mark?.icon, "troll")
        XCTAssertEqual(between.inlineText, "Streak 4 · Bounty: Fen Troll")
        XCTAssertEqual(between.bountyDistanceLine, "2.4 km away")
        XCTAssertEqual(between.streakLine, "4-day streak")

        let ranOut = WatchComplication(idle: idle, quarry: nil, at: now.addingTimeInterval(7200))
        XCTAssertNil(ranOut.mark, "a bounty that has run out is not shown")
        XCTAssertEqual(ranOut.inlineText, "Streak 4")

        let empty = WatchComplication(idle: nil, quarry: nil, at: now)
        XCTAssertNil(empty.mark)
        XCTAssertEqual(empty.inlineText, "Roads & Runes")
        XCTAssertEqual(empty.streakLine, "Start a streak")
        XCTAssertNil(empty.bountyDistanceLine)

        var imperial = idle
        imperial.units = "IMPERIAL"
        XCTAssertEqual(WatchComplication(idle: imperial, quarry: nil, at: now).bountyDistanceLine, "1.5 mi away")
    }

    func testTheComplicationIsWorkedOutAgainWhenTheBountyEndsAndAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9))!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6))!
        let ends = morning.addingTimeInterval(3600)
        let idle = WatchIdleInfo(bounty: .init(name: "Fen Troll", expiresAt: ends), updatedAt: morning)
        XCTAssertEqual(WatchComplication.refreshDates(idle: idle, after: morning, calendar: calendar), [ends, midnight])
        XCTAssertEqual(WatchComplication.refreshDates(idle: nil, after: morning, calendar: calendar), [midnight])
    }
}
