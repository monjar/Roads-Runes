import RoadsAndRunesArt
import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// 0.7.3's in-app features: a quick start plans and starts, the sealed goal stays
/// shut until halfway and is read only standing still, the pledge round-trips, and
/// the share card says nothing about where unless asked.
@MainActor
final class BetweenRidesAppTests: XCTestCase {
    /// The coordinator holds its container weakly, as the app's does: the test keeps it.
    private var container: AppContainer?

    private func ready() async -> (AppContainer, QuickStartCoordinator) {
        let container = AppContainer(api: MockAPI(), inMemory: true)
        self.container = container
        await container.session.bootstrap()
        let coordinator = QuickStartCoordinator(container: container)
        coordinator.locate = { _ in SampleData.origin }
        coordinator.patience = .milliseconds(300)
        return (container, coordinator)
    }

    // MARK: Quick start

    func testALoopIsPlannedReadyToStartAndNotStarted() async {
        let (container, coordinator) = await ready()
        let outcome = await coordinator.run(.loop(minutes: 40, activity: .run), autoStart: false)
        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(coordinator.phase, .ready)
        XCTAssertTrue(coordinator.isPresented, "the route card is on screen")
        XCTAssertEqual(coordinator.plan?.activity, .run)
        XCTAssertEqual(coordinator.plan?.title, "40-minute loop")
        XCTAssertNotNil(coordinator.route)
        XCTAssertFalse(container.rideRecorder.isActive, "nothing starts without a tap")
    }

    func testFromTheWatchItStartsWithoutATap() async {
        let (container, coordinator) = await ready()
        let outcome = await coordinator.run(.loop(minutes: 20, activity: .ride), autoStart: true)
        XCTAssertEqual(outcome, .started)
        XCTAssertTrue(container.rideRecorder.isActive)
        XCTAssertFalse(coordinator.isPresented, "the card is gone for the ride")
        XCTAssertEqual(container.rideRecorder.activity, .ride)
        XCTAssertNotNil(container.rideRecorder.package)
        container.rideRecorder.discard()
    }

    func testASealedQuestComesWithItsOwnRoute() async throws {
        let (_, coordinator) = await ready()
        let outcome = await coordinator.run(.sealed(minutes: 40), autoStart: false)
        XCTAssertEqual(outcome, .ready)
        let quest = try XCTUnwrap(coordinator.quest)
        XCTAssertTrue(SealedQuest.isSealed(quest))
        XCTAssertEqual(quest.title, "Sealed quest (40 min)")
        XCTAssertEqual(coordinator.route?.id, quest.suggestedRouteId, "the quest's own route")
    }

    func testTheBountyAndAQuestOnTheBoardArePlanned() async {
        let (_, coordinator) = await ready()
        let bounty = await coordinator.run(.bounty, autoStart: false)
        XCTAssertEqual(bounty, .ready)
        XCTAssertEqual(coordinator.plan?.quarryId, SampleData.sampleMonster.id, "the bounty is the journey's quarry")
        XCTAssertEqual(coordinator.plan?.destination?.name, SampleData.sampleMonster.name)
        let quest = await coordinator.run(.quest(id: SampleData.questId), autoStart: false)
        XCTAssertEqual(quest, .ready)
        XCTAssertEqual(coordinator.quest?.id, SampleData.questId)
    }

    func testAFailureSaysWhyInPlainWords() async {
        let (_, coordinator) = await ready()
        let gone = await coordinator.run(.quest(id: UUID()), autoStart: false)
        guard case .failed(let line) = gone else { return XCTFail("a quest that isn't there can't be planned") }
        XCTAssertFalse(line.isEmpty)
        XCTAssertEqual(coordinator.phase, .failed(line), "the card shows the line and the planner")

        coordinator.locate = { _ in nil }
        let nowhere = await coordinator.run(.loop(minutes: 20, activity: .walk), autoStart: true)
        XCTAssertEqual(nowhere, .failed(QuickStartError.noLocation.line))
    }

    func testAStartAskedForBeforeTheAppIsUpWaitsForIt() async {
        let (container, _) = await ready()
        let coordinator = QuickStartCoordinator()
        coordinator.locate = { _ in SampleData.origin }
        let pending = coordinator.handle(.sealed(minutes: 20), autoStart: false)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(coordinator.phase, .idle, "nothing to plan with yet")
        coordinator.attach(container)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .ready)
    }

    func testANewerStartReplacesOneStillPlanning() async {
        let (_, coordinator) = await ready()
        coordinator.locate = { _ in nil }
        let first = coordinator.handle(.loop(minutes: 40, activity: .ride))
        try? await Task.sleep(for: .milliseconds(30))
        coordinator.locate = { _ in SampleData.origin }
        let second = await coordinator.run(.sealed(minutes: 90), autoStart: false)
        XCTAssertEqual(second, .ready)
        _ = await first.value
        XCTAssertEqual(coordinator.request, .sealed(minutes: 90), "the older one changes nothing when it ends")
        XCTAssertEqual(coordinator.phase, .ready)
    }

    // MARK: Sealed goal

    func testTheRideScreenNamesTheGoalOnlyHalfwayAndStandingStill() {
        let quest = SampleData.sealedQuest(minutes: 40, origin: SampleData.origin)
        let objective = quest.objectives[0]
        XCTAssertEqual(ObjectiveBanner.line(for: objective, quest: quest, routeFraction: 0.3, isStill: true), "The goal opens halfway.")
        XCTAssertEqual(ObjectiveBanner.line(for: objective, quest: quest, routeFraction: 0.6, isStill: false), "Your goal is open. Stop to read it.")
        XCTAssertEqual(ObjectiveBanner.line(for: objective, quest: quest, routeFraction: 0.6, isStill: true), "Ride to The Crown")
        let ordinary = SampleData.sampleQuest
        XCTAssertEqual(ObjectiveBanner.line(for: ordinary.objectives[0], quest: ordinary, routeFraction: 0, isStill: false), ordinary.objectives[0].title)
    }

    func testTheQuestCardKeepsTheGoalShutUntilItIsDone() {
        var quest = SampleData.sealedQuest(minutes: 20, origin: SampleData.origin)
        XCTAssertEqual(SealedQuestCopy.shown(quest.objectives[0], in: quest).title, "The goal opens halfway.")
        quest.status = .completed
        XCTAssertEqual(SealedQuestCopy.shown(quest.objectives[0], in: quest).title, "Ride to The Crown")
        XCTAssertEqual(SealedQuestCopy.shown(SampleData.sampleQuest.objectives[0], in: SampleData.sampleQuest), SampleData.sampleQuest.objectives[0])
    }

    // MARK: Pledge

    func testAPledgeIsMadeShownAndTakenBack() async throws {
        let container = AppContainer(api: MockAPI(), inMemory: true)
        await container.session.bootstrap()
        let store = container.pledges
        XCTAssertTrue(store.isOn, "the pledge flag is on in dev")
        let now = Date()
        let made = await store.pledge(.creature, id: SampleData.sampleMonster.id, window: .tomorrow, remindAt: now, now: now)
        XCTAssertTrue(made)
        let pledge = try XCTUnwrap(store.open(for: SampleData.sampleMonster.id))
        XCTAssertEqual(pledge.day, PledgeWindow.tomorrow.day(from: now))
        XCTAssertEqual(pledge.remindAt, PledgeWindow.timeString(now))
        XCTAssertEqual(store.existing(in: .tomorrow)?.targetName, SampleData.sampleMonster.name)
        XCTAssertNil(store.today, "tomorrow's is not on today's Next up")
        XCTAssertEqual(PledgeButton.pledgedLine(pledge, today: PledgeWindow.dayString(now)), "Pledged for tomorrow · reminder at \(PledgeWindow.timeString(now))")

        await store.cancel(pledge)
        XCTAssertNil(store.open(for: SampleData.sampleMonster.id))
    }

    func testAPledgeForSomethingGoneSaysSo() async {
        let container = AppContainer(api: MockAPI(), inMemory: true)
        await container.session.bootstrap()
        let made = await container.pledges.pledge(.quest, id: UUID(), window: .today, remindAt: nil)
        XCTAssertFalse(made)
        XCTAssertEqual(container.pledges.error, "That creature or quest isn't on your map any more. Pick another.")
    }

    func testThePledgeReminderNamesWhatWasPledgedAndNothingElse() {
        let copy = NudgeScheduler.pledgeCopy(for: SampleData.samplePledge)
        XCTAssertEqual(copy.title, "Today's pledge")
        XCTAssertEqual(copy.body, "You pledged to go out for Lock Wraith today.")
        XCTAssertEqual(NudgeScheduler.pledgeID, "pledge.reminder")
    }

    // MARK: Share card

    private func summary(entry: String?, fights: [FightReport] = []) -> AdventureSummary {
        var summary = SampleData.sampleAdventureSummary
        summary.entry = entry
        summary.worldObjects = WorldObjectOutcome(claimed: [], missed: [], fights: fights)
        return summary
    }

    private func report(_ outcome: String, name: String, after: Int = 0) -> FightReport {
        FightReport(id: UUID(), name: name, speciesId: "fen-troll", tier: 1, outcome: outcome, holdMax: 400, holdBefore: 400, holdAfter: after,
                    damage: ["ROAD": 400 - after], finisher: outcome == "SEEN_OFF" ? "CLIMB" : nil)
    }

    func testTheCardCarriesTheCreatureTheLineAndNoRouteByDefault() {
        let card = ShareCardContent.make(
            summary: summary(entry: "You rode out under a grey sky. Then it rained.", fights: [report("LOOSENED", name: "Grey Stag", after: 31), report("SEEN_OFF", name: "Fen Troll")]),
            character: SampleData.sampleCharacter, units: .metric
        )
        XCTAssertEqual(card.creature?.name, "Fen Troll", "the one defeated comes first")
        XCTAssertEqual(card.creature?.line, "Fen Troll defeated! Finished with climbing.")
        XCTAssertEqual(card.creature?.health, "Health 0 / 400")
        XCTAssertEqual(card.sentence, "You rode out under a grey sky.")
        XCTAssertNil(card.trace, "no route unless asked")
    }

    func testAFirstSentenceNamingAPlaceStaysOffTheCard() {
        let card = ShareCardContent.make(summary: summary(entry: "You passed The Crown twice. A good day."), character: nil, units: .metric)
        XCTAssertNil(card.sentence, "The Crown is a place the journey found")
        XCTAssertEqual(ShareCardContent.firstSentence(of: "No full stop here"), "No full stop here")
        XCTAssertNil(ShareCardContent.firstSentence(of: "   "))
    }

    func testTheCardRendersToAPicture() {
        let content = ShareCardContent.make(summary: summary(entry: "A quiet loop.", fights: [report("SEEN_OFF", name: "Fen Troll")]),
                                            character: SampleData.sampleCharacter, units: .metric,
                                            trace: TraceMask.shareable(SampleData.sampleRoute.path + SampleData.sampleRoute.path))
        let image = ShareCardView.render(content, scale: 1)
        XCTAssertEqual(image?.size.width ?? 0, ShareCardView.size.width, accuracy: 1)
        XCTAssertEqual(image?.size.height ?? 0, ShareCardView.size.height, accuracy: 1)
    }
}
