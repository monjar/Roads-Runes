import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunesWatch

@MainActor
final class RideStoreTests: XCTestCase {
    private func instruction(_ index: Int, sign: InstructionSign = .right, street: String = "Rotherhithe Street") -> Instruction {
        Instruction(index: index, text: "Turn right onto \(street)", streetName: street, sign: sign, distanceMeters: 180,
                    durationSeconds: 40, coordinateIndex: index * 10, latitude: 51.5, longitude: -0.04)
    }

    private func update(state: NavigationState = .active, instruction: Instruction?, elapsed: Double = 100) -> WatchNavigationUpdate {
        WatchNavigationUpdate(state: state, instruction: instruction, distanceToInstructionMeters: 150, nextInstructionText: "Left onto Mill Road",
                              objectiveTitle: "Reach Old Station", objectiveDistanceMeters: 1400, distanceMeters: 12600, elapsedSeconds: elapsed,
                              elevationGainMeters: 140, heartRate: 132, speedMps: 6.4, timestamp: Date())
    }

    func testNavigationUpdateRoundTripThroughWatchMessages() throws {
        let original = update(instruction: instruction(1))
        let message = try WatchMessages.navigationUpdate(original)
        XCTAssertEqual(WatchMessages.kind(of: message), .navigationUpdate)
        let decoded = try WatchMessages.navigationUpdate(from: message)
        XCTAssertEqual(decoded.state, .active)
        XCTAssertEqual(decoded.instruction?.streetName, "Rotherhithe Street")
        XCTAssertEqual(decoded.distanceMeters, 12600)
        XCTAssertEqual(decoded.heartRate, 132)
    }

    func testTheRiderDotPointsTheWayTheRiderIsGoing() throws {
        // An older phone sends positions and no course: the Watch works it out.
        let store = RideStore()
        XCTAssertNil(store.riderCourse)
        var moving = update(instruction: instruction(1))
        moving.latitude = 51.4900
        moving.longitude = -0.0400
        store.apply(update: moving)
        XCTAssertNil(store.riderCourse, "no direction before the rider has moved")
        moving.latitude = 51.4902 // about 22 m north
        store.apply(update: moving)
        XCTAssertEqual(try XCTUnwrap(store.riderCourse), 0, accuracy: 2)
        // A phone that sends its course is believed over the guess.
        moving.courseDegrees = 270
        store.apply(update: moving)
        XCTAssertEqual(store.riderCourse, 270)
        // And the course survives the trip through the Watch messages.
        let decoded = try WatchMessages.navigationUpdate(from: WatchMessages.navigationUpdate(moving))
        XCTAssertEqual(decoded.courseDegrees, 270)
    }

    func testStalenessGrowsWithoutMessages() {
        let store = RideStore()
        XCTAssertTrue(store.isStale())
        let received = Date(timeIntervalSince1970: 1_000)
        store.apply(update: update(instruction: instruction(1)), receivedAt: received)
        XCTAssertEqual(store.staleness(at: received.addingTimeInterval(10)), 10, accuracy: 0.001)
        XCTAssertFalse(store.isStale(at: received.addingTimeInterval(30)))
        XCTAssertTrue(store.isStale(at: received.addingTimeInterval(RideStore.staleAfter + 1)))
    }

    func testLastInstructionKeptWhenUpdateHasNone() {
        let store = RideStore()
        store.apply(update: update(instruction: instruction(1)))
        XCTAssertEqual(store.currentInstruction?.index, 1)
        store.apply(update: update(instruction: nil, elapsed: 130))
        XCTAssertEqual(store.currentInstruction?.index, 1)
        XCTAssertEqual(store.update?.elapsedSeconds, 130)
    }

    func testElapsedTicksLocallyWhileActive() {
        let store = RideStore()
        let received = Date(timeIntervalSince1970: 5_000)
        store.apply(update: update(state: .active, instruction: instruction(1), elapsed: 100), receivedAt: received)
        XCTAssertEqual(store.elapsedSeconds(at: received.addingTimeInterval(7)), 107, accuracy: 0.001)
        store.apply(update: update(state: .paused, instruction: instruction(1), elapsed: 110), receivedAt: received)
        XCTAssertEqual(store.elapsedSeconds(at: received.addingTimeInterval(20)), 110, accuracy: 0.001)
    }

    func testTerminalStateClearsRoute() {
        let store = RideStore()
        store.apply(summary: WatchRouteSummary(questTitle: "The Forgotten Railway", instructions: [instruction(0)], objectives: [], totalDistanceMeters: 30000))
        XCTAssertTrue(store.hasRoute)
        store.apply(update: update(state: .completed, instruction: nil))
        XCTAssertFalse(store.hasRoute)
        XCTAssertNil(store.currentInstruction)
    }

    func testATurnComingUpTapsTheWristOnceAndAgainWhenItIsHere() {
        let store = RideStore()
        func near(_ meters: Double) -> WatchNavigationUpdate {
            WatchNavigationUpdate(state: .active, instruction: instruction(2, sign: .left), distanceToInstructionMeters: meters, distanceMeters: 1000, elapsedSeconds: 100, elevationGainMeters: 0, timestamp: Date())
        }
        store.apply(update: near(400))
        XCTAssertEqual(store.turnCueToken, 0)
        store.apply(update: near(140))
        XCTAssertEqual(store.turnCue, .approaching(.left))
        XCTAssertEqual(store.turnCueToken, 1)
        store.apply(update: near(100))
        XCTAssertEqual(store.turnCueToken, 1)
        store.apply(update: near(25))
        XCTAssertEqual(store.turnCue, .now(.left))
        XCTAssertEqual(store.turnCueToken, 2)
        // Paused at the junction: nothing more to say about it.
        var paused = near(10)
        paused.state = .paused
        store.apply(update: paused)
        XCTAssertEqual(store.turnCueToken, 2)
    }

    func testAClaimCarriesItsCoinsAndItsSetToTheWrist() throws {
        let store = RideStore()
        let message = try WatchMessages.objectiveCompleted(WatchObjectiveCompleted(title: "Found: Raido (Old Runes)", coins: 10, detail: "Old Runes, 3 of 6"))
        store.apply(objective: try WatchMessages.objectiveCompleted(from: message))
        XCTAssertEqual(store.pendingObjective?.coins, 10)
        XCTAssertEqual(store.pendingObjective?.detail, "Old Runes, 3 of 6")
        XCTAssertEqual(store.objectiveToken, 1)
    }

    // MARK: - The game on the wrist (0.7.2)

    private let troll = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000F1")!
    private let chest = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000C1")!
    private let flag = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000B1")!

    private func summary(marks: [WatchWorldMark]? = nil, stops: [WatchStop] = []) -> WatchRouteSummary {
        WatchRouteSummary(questTitle: "The Forgotten Railway", instructions: [instruction(0)], objectives: [], totalDistanceMeters: 30_000,
                          stops: stops, activity: "RIDE", worldMarks: marks)
    }

    private var marks: [WatchWorldMark] {
        [
            WatchWorldMark(id: troll, kind: WatchWorldMark.monster, name: "Fen Troll", latitude: 51.49, longitude: -0.03, icon: "troll",
                           speciesId: "fen-troll", tier: 1, quarry: true),
            WatchWorldMark(id: chest, kind: WatchWorldMark.chest, name: "Old chest", latitude: 51.48, longitude: -0.02, icon: "chest", tier: 2),
            WatchWorldMark(id: flag, kind: WatchWorldMark.objective, name: "Reach Old Station", latitude: 51.50, longitude: -0.01, icon: "flag"),
        ]
    }

    private func gone(_ ids: [UUID]?, state: NavigationState = .active, fight: WatchFight? = nil) -> WatchNavigationUpdate {
        var next = update(state: state, instruction: instruction(1))
        next.goneMarkIds = ids
        next.fight = fight
        return next
    }

    func testWorldMarksComeWithTheRouteAndComeOffWhenTaken() throws {
        let store = RideStore()
        store.apply(summary: try WatchMessages.routeSummary(from: WatchMessages.routeSummary(summary(marks: marks))))
        XCTAssertEqual(store.worldMarks.map(\.id), [troll, chest, flag])

        store.apply(update: try WatchMessages.navigationUpdate(from: WatchMessages.navigationUpdate(gone([chest]))))
        XCTAssertEqual(store.worldMarks.map(\.id), [troll, flag])
        store.apply(update: gone(nil))
        XCTAssertEqual(store.worldMarks.map(\.id), [troll, flag], "an update that says nothing brings nothing back")
        store.apply(update: gone([chest, flag]))
        XCTAssertEqual(store.worldMarks.map(\.id), [troll])

        // A reroute is the same journey: what is gone stays gone.
        store.apply(summary: summary(marks: marks))
        XCTAssertEqual(store.worldMarks.map(\.id), [troll])

        store.apply(update: gone(nil, state: .completed))
        XCTAssertTrue(store.worldMarks.isEmpty)
        XCTAssertTrue(store.goneMarkIds.isEmpty)
        // The next journey starts with all of its marks.
        store.apply(summary: summary(marks: marks))
        XCTAssertEqual(store.worldMarks.count, 3)
    }

    func testTheQuarryAndBountiesAreMarkedAndUnknownIconsFallBack() throws {
        let quarry = try XCTUnwrap(marks.first)
        XCTAssertEqual(WristMarks.size(quarry), 24)
        XCTAssertEqual(WristMarks.size(marks[1]), 16)
        XCTAssertEqual(WristMarks.size(marks[2]), 20)
        XCTAssertEqual(WristMarks.icon("troll", species: "bog-wraith", otherwise: .dragonHead).rawValue, "troll")
        // A newer phone may name an icon this Watch has not got: the species, then the kind, stand in.
        XCTAssertEqual(WristMarks.icon("hedgeDragonOfTheFuture", species: "fen-troll", otherwise: .dragonHead).rawValue, "troll")
        XCTAssertEqual(WristMarks.icon("hedgeDragonOfTheFuture", species: nil, otherwise: .runeStone).rawValue, "runeStone")
        XCTAssertEqual(WristMarks.rarityWord("LEGENDARY"), "Legendary")
        XCTAssertNil(WristMarks.rarityWord(nil))
    }

    func testStopsWithAKindDrawAsPlacesAndAnOlderPhonesAsDots() throws {
        let pub = WatchStop(id: UUID(), name: "The Crown", latitude: 51.49, longitude: -0.03, requested: true, category: "PUB")
        let plain = WatchStop(id: UUID(), name: "The Mill", latitude: 51.49, longitude: -0.03, requested: false)
        let store = RideStore()
        store.apply(summary: try WatchMessages.routeSummary(from: WatchMessages.routeSummary(summary(stops: [pub, plain]))))
        XCTAssertEqual(store.stops.map(\.category), ["PUB", nil])
        XCTAssertNotNil(WristMarks.stop(store.stops[0]))
        XCTAssertNil(WristMarks.stop(store.stops[1]), "no kind from an older phone: the old dot")
        XCTAssertTrue(store.worldMarks.isEmpty, "an older phone sends no world marks")
    }

    func testTheFightComesWithEachUpdateInTenths() throws {
        let store = RideStore()
        XCTAssertNil(store.fight)
        let fight = WatchFight(speciesId: "fen-troll", name: "Fen Troll", icon: "troll", tenthsLeft: 6, quarry: true, defeated: false)
        store.apply(update: try WatchMessages.navigationUpdate(from: WatchMessages.navigationUpdate(gone(nil, fight: fight))))
        XCTAssertEqual(store.fight, fight)
        store.apply(update: gone(nil))
        XCTAssertNil(store.fight, "an older phone, or nothing being fought")
        // The ring lands on whole tenths, never a tick more or less.
        for tenths in 0...10 {
            XCTAssertEqual(WatchFight.tenths(FightRing.fraction(tenths: tenths)), tenths)
        }
    }

    func testADropComesToTheOverlayWithItsMarkAndRarity() throws {
        let store = RideStore()
        let drop = WatchObjectiveCompleted.found(name: "Tin Bell", icon: "tinBell", rarity: "RARE")
        store.apply(objective: try WatchMessages.objectiveCompleted(from: WatchMessages.objectiveCompleted(drop)))
        XCTAssertEqual(store.pendingObjective?.outcome, "FOUND")
        XCTAssertEqual(store.pendingObjective?.icon, "tinBell")
        XCTAssertEqual(WristMarks.rarityWord(store.pendingObjective?.rarity), "Rare")
    }

    private func end(endedAt: Date?, coins: Int = 120) -> WatchJourneyEnd {
        WatchJourneyEnd(activity: "RIDE", creaturesDefeated: 2, chestsOpened: 1, coins: coins, xp: 340, levelReached: 8,
                        finds: [WatchFind(name: "Tin Bell", icon: "tinBell", rarity: "COMMON")], endedAt: endedAt)
    }

    func testJourneysEndShowsAfterTheJourneyUntilDone() throws {
        let store = RideStore()
        let now = Date(timeIntervalSince1970: 100_000)
        store.apply(summary: summary(), receivedAt: now.addingTimeInterval(-1_200))
        store.apply(update: update(state: .active, instruction: instruction(1), elapsed: 1_190), receivedAt: now.addingTimeInterval(-10))
        // It can overtake the phone's last update: it is kept, and shows once the journey is over.
        let message = try WatchMessages.journeyEnd(end(endedAt: now.addingTimeInterval(-5)))
        store.apply(journeyEnd: try WatchMessages.journeyEnd(from: message), receivedAt: now)
        XCTAssertEqual(store.journeyEnd?.coins, 120)
        XCTAssertEqual(store.journeyEndToken, 1)
        store.apply(update: update(state: .completed, instruction: nil, elapsed: 1_200), receivedAt: now)
        XCTAssertFalse(store.hasRoute)
        XCTAssertFalse(store.isRiding)
        XCTAssertNotNil(store.journeyEnd)
        store.dismissJourneyEnd()
        XCTAssertNil(store.journeyEnd, "Done: back to idle")
    }

    func testAJourneysEndHeardOfTooLateIsLetGo() {
        let store = RideStore()
        let now = Date(timeIntervalSince1970: 100_000)
        store.apply(journeyEnd: end(endedAt: now.addingTimeInterval(-2 * 3_600)), receivedAt: now)
        XCTAssertNil(store.journeyEnd, "hours later, it is old news")
        // The last journey's end, arriving five minutes into the next one.
        store.apply(summary: summary(), receivedAt: now.addingTimeInterval(-300))
        store.apply(update: update(state: .active, instruction: instruction(1), elapsed: 300), receivedAt: now)
        store.apply(journeyEnd: end(endedAt: now.addingTimeInterval(-900)), receivedAt: now)
        XCTAssertNil(store.journeyEnd)
        // A phone that sends no time is believed.
        let idle = RideStore()
        idle.apply(journeyEnd: end(endedAt: nil), receivedAt: now)
        XCTAssertNotNil(idle.journeyEnd)
        // A new journey makes an unread one old news.
        idle.apply(summary: summary(), receivedAt: now)
        XCTAssertNil(idle.journeyEnd)
    }

    func testJourneysEndSaysWhatTheJourneyCameTo() {
        var full = end(endedAt: nil)
        full.finds += (1...7).map { WatchFind(name: "Place \($0)", icon: "tavern") }
        let lines = JourneyEndCard.lines(for: full).map(\.text)
        XCTAssertEqual(Array(lines.prefix(5)), ["Level up!", "2 creatures defeated", "1 chest opened", "+120 coins", "+340 XP"])
        XCTAssertEqual(lines[5], "Tin Bell")
        XCTAssertEqual(JourneyEndCard.lines(for: full)[5].detail, "Common")
        XCTAssertEqual(lines.count, 5 + JourneyEndCard.findsShown + 1)
        XCTAssertEqual(lines.last, "2 more on your iPhone")

        let one = WatchJourneyEnd(creaturesDefeated: 1, chestsOpened: 3)
        XCTAssertEqual(JourneyEndCard.lines(for: one).map(\.text), ["1 creature defeated", "3 chests opened"])
        XCTAssertEqual(JourneyEndCard.lines(for: WatchJourneyEnd()).map(\.text), ["Saved to your Journal"])
    }

    // MARK: Between rides (0.7.3)

    func testNextUpIsKeptAndALateOneDoesNotReplaceANewer() {
        let store = RideStore()
        var faces = 0
        store.onFaceChanged = { faces += 1 }
        let now = Date(timeIntervalSince1970: 200_000)
        let newer = WatchIdleInfo(streakDays: 4, bounty: .init(name: "Fen Troll"), units: "IMPERIAL", updatedAt: now)
        store.apply(idle: newer)
        XCTAssertEqual(store.idle, newer)
        XCTAssertEqual(store.units, .imperial, "Next up carries the units for the complication")
        XCTAssertEqual(faces, 1)
        store.apply(idle: WatchIdleInfo(streakDays: 3, updatedAt: now.addingTimeInterval(-60)))
        XCTAssertEqual(store.idle?.streakDays, 4, "heard late, made earlier: let go")
        // What the app group kept shows until the phone speaks, and never over what it said.
        let fresh = RideStore()
        fresh.restore(idle: WatchIdleInfo(streakDays: 2, updatedAt: now))
        XCTAssertEqual(fresh.idle?.streakDays, 2)
        store.restore(idle: WatchIdleInfo(streakDays: 1, updatedAt: now))
        XCTAssertEqual(store.idle?.streakDays, 4)
    }

    func testPlanningLastsUntilTheRideComes() {
        let store = RideStore()
        let now = Date(timeIntervalSince1970: 300_000)
        let request = WatchStartRequest.loop(minutes: 40, activity: .ride)
        store.beginPlanning(request, at: now)
        XCTAssertTrue(store.isPlanning)
        // "It started" changes nothing on its own: the route summary is the answer.
        store.apply(startResult: WatchStartResult(requestId: request.id, started: true))
        XCTAssertTrue(store.isPlanning)
        store.expirePlanning(at: now.addingTimeInterval(RideStore.planningTimeout - 1))
        XCTAssertTrue(store.isPlanning)
        store.apply(summary: summary(), receivedAt: now.addingTimeInterval(20))
        XCTAssertNil(store.planning, "the ride came")
        XCTAssertTrue(store.hasRoute)
    }

    func testPlanningFailsWhenThePhoneSaysSoOrTakesTooLong() {
        let store = RideStore()
        let now = Date(timeIntervalSince1970: 300_000)
        let first = WatchStartRequest.bounty(activity: .run)
        store.beginPlanning(first, at: now)
        store.apply(startResult: WatchStartResult(requestId: UUID(), started: false))
        XCTAssertTrue(store.isPlanning, "an answer to another question")
        store.apply(startResult: WatchStartResult(requestId: first.id, started: false))
        XCTAssertTrue(store.planningFailed)
        store.dismissPlanning()
        XCTAssertNil(store.planning)

        let second = WatchStartRequest.quest(id: UUID())
        store.beginPlanning(second, at: now)
        store.failPlanning(id: first.id)
        XCTAssertTrue(store.isPlanning, "the old request's failure is not this one's")
        store.expirePlanning(at: now.addingTimeInterval(RideStore.planningTimeout))
        XCTAssertTrue(store.planningFailed)
    }

    func testTheQuarryIsForTheComplicationWhileTheJourneyLasts() {
        let store = RideStore()
        XCTAssertNil(store.quarry)
        var faces = 0
        store.onFaceChanged = { faces += 1 }
        store.apply(summary: summary(marks: marks))
        XCTAssertEqual(store.quarry, WatchQuarry(name: "Fen Troll", icon: "troll", speciesId: "fen-troll"))
        XCTAssertEqual(faces, 1)
        var gone = update(instruction: instruction(1))
        gone.goneMarkIds = [troll]
        store.apply(update: gone)
        XCTAssertNil(store.quarry, "defeated: the bounty or the streak takes the face again")
        store.apply(summary: summary(marks: marks))
        store.markEnded()
        XCTAssertNil(store.quarry)
        XCTAssertEqual(faces, 4)
    }

    // MARK: Legends (0.8.0)

    private let dragon = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000D1")!
    private let lair = UUID(uuidString: "8A1F0B2C-0000-4000-8000-0000000000A2")!

    private var legendMarks: [WatchWorldMark] {
        [
            WatchWorldMark(id: dragon, kind: WatchWorldMark.legend, name: "The Fog Dragon", latitude: 51.49, longitude: -0.03,
                           icon: "fogDragon", speciesId: "fog-dragon", quarry: true),
            WatchWorldMark(id: lair, kind: WatchWorldMark.lair, name: "Southwark Park", latitude: 51.495, longitude: -0.05, icon: "lair"),
        ] + marks.dropFirst()
    }

    private func legendFight(phase: Int = 2, tenths: Int = 6, defeated: Bool = false, quarry: Bool = true) -> WatchFight {
        WatchFight(speciesId: "fog-dragon", name: "The Fog Dragon", icon: "fogDragon", tenthsLeft: tenths, quarry: quarry,
                   defeated: defeated, phase: phase, phases: 3)
    }

    func testTheLegendIsOnTheMapLargerAndGoldAndTheLairAsItsMiddle() throws {
        let store = RideStore()
        store.apply(summary: try WatchMessages.routeSummary(from: WatchMessages.routeSummary(summary(marks: legendMarks))))
        XCTAssertEqual(store.worldMarks.map(\.kind), [WatchWorldMark.legend, WatchWorldMark.lair, WatchWorldMark.chest, WatchWorldMark.objective])
        let legend = store.worldMarks[0]
        XCTAssertGreaterThan(WristMarks.size(legend), WristMarks.size(marks[0]), "larger than a creature quarry")
        XCTAssertEqual(WristMarks.mark(legend), .token(.fogDragon, ring: .gold))
        // Its species stands in for a mark this Watch has not got.
        var unknown = legend
        unknown.icon = "frostDragonOfTheFuture"
        XCTAssertEqual(WristMarks.mark(unknown), .token(.fogDragon, ring: .gold))
        // The lair's tiles are too small for the wrist: one mark at its middle.
        XCTAssertEqual(WristMarks.mark(store.worldMarks[1]), .token(.lair, ring: .sage))
        XCTAssertEqual(WristMarks.size(store.worldMarks[1]), 20)
        // The complication shows the legend while it is the quarry.
        XCTAssertEqual(store.quarry, WatchQuarry(name: "The Fog Dragon", icon: "fogDragon", speciesId: "fog-dragon", legend: true))
        // A phase broken is not gone: the phone sends its id only once it is defeated.
        store.apply(update: gone([dragon]))
        XCTAssertNil(store.quarry)
        XCTAssertFalse(store.worldMarks.contains { $0.isLegend })
    }

    func testALegendsFightIsDrawnInItsThreePhases() throws {
        let store = RideStore()
        store.apply(update: try WatchMessages.navigationUpdate(from: WatchMessages.navigationUpdate(gone(nil, fight: legendFight()))))
        let fight = try XCTUnwrap(store.fight)
        XCTAssertTrue(fight.isLegend)
        XCTAssertEqual(PhaseRing.arcs(for: fight), [.broken, .current(tenths: 6), .whole], "broken filled, this one in tenths, the next whole")
        XCTAssertEqual(PhaseRing.arcs(for: legendFight(phase: 1, tenths: 10)), [.current(tenths: 10), .whole, .whole])
        XCTAssertEqual(PhaseRing.arcs(for: legendFight(phase: 3, tenths: 1)), [.broken, .broken, .current(tenths: 1)])
        XCTAssertEqual(PhaseRing.arcs(for: legendFight(phase: 3, tenths: 0, defeated: true)), [.broken, .broken, .broken])
        XCTAssertEqual(PhaseRing.label(for: fight), "The Fog Dragon, phase 2 of 3, health 6 of 10")
        // Its phases ring it, so its mark goes bare: no quarry ring inside the arcs.
        XCTAssertEqual(WristMarks.fight(fight), .token(.fogDragon))
        // A creature's fight is as it was.
        let troll = WatchFight(speciesId: "fen-troll", name: "Fen Troll", icon: "troll", tenthsLeft: 4, quarry: true, defeated: false)
        XCTAssertFalse(troll.isLegend)
        XCTAssertEqual(WristMarks.fight(troll), .token(.troll, ring: .terracotta))
    }

    func testAPhaseBrokenIsOneFightTapAndTheOverlayWithItsMark() throws {
        let store = RideStore()
        let broken = WatchObjectiveCompleted.phaseBroken(name: "The Fog Dragon", icon: "fogDragon", broken: 1, of: 3)
        store.apply(objective: try WatchMessages.objectiveCompleted(from: WatchMessages.objectiveCompleted(broken)))
        let event = try XCTUnwrap(store.pendingObjective)
        XCTAssertEqual(store.objectiveToken, 1, "one overlay")
        XCTAssertEqual(event.outcome, "PHASE")
        XCTAssertEqual(WristMarks.heading(event), "PHASE BROKEN!")
        XCTAssertEqual(WristMarks.claim(event), .token(.fogDragon, ring: .gold))
        XCTAssertEqual(event.detail, "2 phases left")
        XCTAssertEqual(event.tap, .success)
        XCTAssertTrue(WristTap.fight.contains(event.tap))
        XCTAssertFalse(WristTap.turns.contains(event.tap), "never mistaken for a turn")
        // The headings the older outcomes always had.
        XCTAssertEqual(WristMarks.heading(WatchObjectiveCompleted(title: "Fen Troll", outcome: "GONE")), "DEFEATED")
        XCTAssertEqual(WristMarks.heading(WatchObjectiveCompleted(title: "Old chest", outcome: "OPENED")), "OPENED")
        XCTAssertEqual(WristMarks.heading(WatchObjectiveCompleted(title: "Reach Old Station")), "DONE")
    }

    func testJourneysEndListsTheLegendTheLairAndTreasure() {
        var full = end(endedAt: nil)
        full.legend = WatchEndLine(text: "Phase broken! The Fog Dragon is down to its last phase.", icon: "fogDragon")
        full.lair = WatchEndLine.lair(name: "Southwark Park", visited: 5, need: 5, done: true)
        full.treasureFound = WatchEndLine.treasure(coins: 120)
        let lines = JourneyEndCard.lines(for: full)
        XCTAssertEqual(lines.map(\.text), [
            "Level up!", "Phase broken! The Fog Dragon is down to its last phase.", "2 creatures defeated", "1 chest opened",
            "Great chest opened", "+120 coins", "+340 XP", "Buried treasure found", "Tin Bell",
        ])
        XCTAssertEqual(lines[1].mark, .token(.fogDragon, ring: .gold))
        XCTAssertEqual(lines[4].mark, .token(.greatChest, ring: .gold))
        XCTAssertEqual(lines[4].detail, "Southwark Park")
        XCTAssertEqual(lines[7].detail, "+120 coins")
        let visiting = WatchJourneyEnd(lair: WatchEndLine.lair(name: "Southwark Park", visited: 3, need: 5, done: false))
        XCTAssertEqual(JourneyEndCard.lines(for: visiting).map(\.text), ["Lair: 3 of 5 tiles"])
        XCTAssertEqual(JourneyEndCard.lines(for: visiting).first?.mark, .token(.lair, ring: .sage))
    }
}
