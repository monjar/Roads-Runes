import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// 0.7.3's extensions, app side: the intents ask for the right quick start, the
/// Live Activity follows the ride's navigation updates, the widgets' snapshot is
/// built from what the app holds, and links land on the right tab.
@MainActor
final class BetweenRidesExtensionsTests: XCTestCase {
    // MARK: Intents

    func testStartJourneyAsksForALoop() {
        var intent = StartJourneyIntent()
        intent.kind = .run
        intent.minutes = 30
        XCTAssertEqual(intent.quickStart, .loop(minutes: 30, activity: .run))
        // Said with no activity: the coordinator uses the player's usual one.
        intent.kind = nil
        XCTAssertEqual(intent.quickStart, .loop(minutes: 30, activity: .unknown))
    }

    func testBountyIntentAsksForTheBounty() {
        XCTAssertEqual(BountyJourneyIntent().quickStart, .bounty)
    }

    func testQuickQuestAsksForASealedQuest() {
        var intent = QuickQuestIntent()
        intent.length = .forty
        XCTAssertEqual(intent.quickStart, .sealed(minutes: 40))
        intent.length = .ninety
        XCTAssertEqual(intent.quickStart, .sealed(minutes: 90))
        XCTAssertEqual(QuestLength(minutes: 45), .forty)
        XCTAssertEqual(QuestLength(minutes: 15), .twenty)
        XCTAssertEqual(JourneyKind.walk.activity, .walk)
    }

    // MARK: Deep links

    func testLinksOpenATabOrAQuickStart() {
        let inbox = DeepLinkInbox()
        var started: [QuickStart] = []
        inbox.quickStart = { started.append($0) }

        XCTAssertTrue(inbox.open(URL(string: "roadsandrunes://quests")!))
        XCTAssertEqual(inbox.takeDestination(), .quests)
        XCTAssertNil(inbox.takeDestination())

        XCTAssertTrue(inbox.open(URL(string: "roadsandrunes://quickstart?minutes=40")!))
        XCTAssertEqual(started, [.sealed(minutes: 40)])
        XCTAssertNil(inbox.destination)

        // Strava's return goes to the container.
        XCTAssertFalse(inbox.open(URL(string: "roadsandrunes://strava?code=abc")!))

        XCTAssertEqual(AppTab(link: .bounty), .world)
        XCTAssertEqual(AppTab(link: .world), .world)
        XCTAssertEqual(AppTab(link: .quests), .quests)
        XCTAssertNil(AppTab(link: .ride))
    }

    // MARK: Live Activity

    private final class FakeSink: RideActivitySink {
        var started: [(RideActivityAttributes, RideActivityState)] = []
        var updates: [RideActivityState] = []
        var ended: [RideActivityState?] = []
        var isRunning: Bool { !started.isEmpty && ended.isEmpty }

        func start(_ attributes: RideActivityAttributes, state: RideActivityState, staleAfter: TimeInterval) {
            started.append((attributes, state))
        }

        func update(_ state: RideActivityState, staleAfter: TimeInterval) { updates.append(state) }
        func endAll(_ state: RideActivityState?) { ended.append(state) }
    }

    private let turn = Instruction(index: 2, text: "Turn left onto Mill Lane", streetName: "Mill Lane", sign: .left, distanceMeters: 300,
                                   durationSeconds: 60, coordinateIndex: 4, latitude: 51.5, longitude: -0.1)

    private func update(_ state: NavigationState, toTurn: Double, ridden: Double, instruction: Instruction? = nil) -> WatchNavigationUpdate {
        WatchNavigationUpdate(
            state: state, instruction: instruction ?? turn, distanceToInstructionMeters: toTurn, distanceMeters: ridden,
            elapsedSeconds: 60, elevationGainMeters: 0,
            fight: WatchFight(speciesId: "fen-troll", name: "Fen Troll", icon: "troll", tenthsLeft: 8, quarry: true, defeated: false)
        )
    }

    func testTheLiveActivityFollowsTheRide() {
        let sink = FakeSink()
        let controller = RideActivityController(sink: sink)
        let t0 = Date()

        // Nothing goes to the lock screen before the journey has begun.
        controller.update(update(.active, toTurn: 300, ridden: 0), at: t0)
        XCTAssertTrue(sink.updates.isEmpty)

        controller.begin(activity: .run, questTitle: "The Mill Road", units: .imperial)
        XCTAssertEqual(sink.started.count, 1)
        XCTAssertEqual(sink.started.first?.0, RideActivityAttributes(activity: "RUN", questTitle: "The Mill Road", units: "IMPERIAL"))
        // A new route keeps the one showing.
        controller.begin(activity: .run, questTitle: "The Mill Road", units: .imperial)
        XCTAssertEqual(sink.started.count, 1)

        controller.update(update(.active, toTurn: 300, ridden: 100), at: t0)
        XCTAssertEqual(sink.updates.count, 1)
        XCTAssertEqual(sink.updates.last?.maneuver, "LEFT")
        XCTAssertEqual(sink.updates.last?.quarryIcon, "troll")
        XCTAssertEqual(sink.updates.last?.quarryTenthsLeft, 8)

        // A second later and a few metres on: held back.
        controller.update(update(.active, toTurn: 280, ridden: 120), at: t0.addingTimeInterval(1))
        XCTAssertEqual(sink.updates.count, 1)
        // A new turn: at once.
        var right = turn
        right.index = 3
        right.sign = .right
        right.text = "Turn right"
        controller.update(update(.active, toTurn: 400, ridden: 140, instruction: right), at: t0.addingTimeInterval(2))
        XCTAssertEqual(sink.updates.count, 2)
        XCTAssertEqual(sink.updates.last?.maneuver, "RIGHT")
        // Five seconds on: the distance catches up.
        controller.update(update(.active, toTurn: 350, ridden: 190, instruction: right), at: t0.addingTimeInterval(7))
        XCTAssertEqual(sink.updates.count, 3)
        XCTAssertEqual(sink.updates.last?.distanceMeters, 190)

        // Saved: it ends with the last state.
        controller.update(update(.completed, toTurn: 0, ridden: 2_000, instruction: right), at: t0.addingTimeInterval(8))
        XCTAssertEqual(sink.ended.count, 1)
        XCTAssertEqual(sink.ended.first??.distanceMeters, 2_000)
    }

    func testDiscardingEndsIt() {
        let sink = FakeSink()
        let controller = RideActivityController(sink: sink)
        controller.begin(activity: .ride, questTitle: nil, units: .metric)
        controller.update(update(.cancelled, toTurn: 0, ridden: 50))
        XCTAssertEqual(sink.ended.count, 1)
        // Nothing more goes after the end.
        controller.update(update(.active, toTurn: 300, ridden: 60))
        XCTAssertTrue(sink.updates.isEmpty)
    }

    func testTestsPutNothingOnTheLockScreen() {
        // The shared controller has no sink under XCTest; this must not crash or start anything.
        RideActivityController.shared.begin(activity: .ride, questTitle: nil, units: .metric)
        RideActivityController.shared.end()
    }

    // MARK: Widget snapshot

    private let here = Coordinate(latitude: 51.49, longitude: -0.04)

    private func creature(bounty: Bool, metersNorth: Double, expiresIn: TimeInterval = 86_400, name: String = "Fen Troll") -> WorldObject {
        WorldObject(
            id: UUID(), kind: .monster, latitude: here.latitude + metersNorth / 111_195, longitude: here.longitude, name: name,
            bounty: bounty, rewardAC: 60, expiresAt: Date().addingTimeInterval(expiresIn),
            monster: MonsterInfo(hp: 100, speciesId: "fen-troll")
        )
    }

    func testTheSnapshotIsBuiltFromWhatTheAppHolds() throws {
        var character = SampleData.sampleCharacter
        character.streakDays = 4
        character.streakActiveToday = true
        let week = WeekNotice(week: "2026-W41", kind: "OUTINGS", title: "Three journeys this week", target: 3, unit: "journeys",
                              progress: 2, done: false, paid: false)
        let counts = try JSONDecoder().decode(CodexCounts.self, from: Data(
            #"{"creaturesSeenOff":3,"creaturesSeen":7,"creaturesTotal":24,"runesHeld":2,"runesTotal":24}"#.utf8
        ))
        let objects = [
            creature(bounty: false, metersNorth: 100, name: "Bog Wraith"),
            creature(bounty: true, metersNorth: 2_400),
            creature(bounty: true, metersNorth: 50, expiresIn: -60, name: "Gone Troll"),
        ]
        let snapshot = WidgetSnapshotWriter.snapshot(
            character: character, objects: objects, position: here, weekNotice: week, codex: counts,
            pledge: .init(targetName: "Fen Troll", icon: "troll"), units: .metric
        )
        XCTAssertEqual(snapshot.streakDays, 4)
        XCTAssertTrue(snapshot.streakActiveToday)
        XCTAssertEqual(snapshot.bounty?.name, "Fen Troll")
        XCTAssertEqual(snapshot.bounty?.icon, "troll")
        XCTAssertEqual(snapshot.bounty?.distanceMeters ?? 0, 2_400, accuracy: 25)
        XCTAssertEqual(snapshot.weekNotice?.title, "Three journeys this week")
        XCTAssertEqual(snapshot.weekNotice?.progress ?? 0, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.codexMet, 7)
        XCTAssertEqual(snapshot.codexTotal, 24)
        XCTAssertEqual(snapshot.level, character.overallLevel)
        XCTAssertEqual(snapshot.pledge?.targetName, "Fen Troll")
        XCTAssertEqual(snapshot.units, .metric)

        let empty = WidgetSnapshotWriter.snapshot(character: nil, objects: [], position: nil, weekNotice: nil, codex: nil, pledge: nil, units: .imperial)
        XCTAssertEqual(empty.streakDays, 0)
        XCTAssertNil(empty.bounty)
        XCTAssertNil(empty.codexMet)
    }

    func testTheWriterSkipsAWriteThatChangesNothing() {
        let suite = "rr-widget-writer-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var reloads = 0
        let writer = WidgetSnapshotWriter(defaults: defaults) { reloads += 1 }

        let first = WidgetSnapshot(updatedAt: Date(), streakDays: 3, streakActiveToday: false)
        writer.save(first)
        XCTAssertEqual(WidgetSnapshot.read(from: defaults), first)
        XCTAssertEqual(reloads, 1)

        // The same again a moment later: no write, no reload.
        var same = first
        same.updatedAt = first.updatedAt.addingTimeInterval(1)
        writer.save(same)
        XCTAssertEqual(reloads, 1)

        var kept = same
        kept.streakActiveToday = true
        kept.streakDays = 4
        writer.save(kept)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(WidgetSnapshot.read(from: defaults)?.streakDays, 4)

        writer.clear()
        XCTAssertNil(WidgetSnapshot.read(from: defaults))
        XCTAssertEqual(reloads, 3)
    }
}
