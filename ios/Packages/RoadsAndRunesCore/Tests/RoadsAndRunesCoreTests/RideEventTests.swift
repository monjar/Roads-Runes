import XCTest
@testable import RoadsAndRunesCore

final class RideEventTests: XCTestCase {
    private let t0 = SampleData.referenceDate

    // MARK: What is said

    func testTheBriefingNamesWhatIsOnTheWay() {
        let event = RideEvent.briefing(chests: 2, pieces: 0, monsters: ["Bog Wraith"])
        XCTAssertEqual(event.pill(), "Two chests and the Bog Wraith on this route")
        XCTAssertEqual(event.spoken(), "Two chests and the Bog Wraith on this route.")
        XCTAssertEqual(RideEvent.briefing(chests: 1, pieces: 3, monsters: ["Fen Troll", "Mire Hag", "Rook Lord"]).pill(), "One chest, three pieces, the Fen Troll, the Mire Hag and one more on this route")
        XCTAssertNil(RideEvent.briefing(chests: 0, pieces: 0, monsters: []).spoken(), "an empty road is not announced")
    }

    func testOnlyWhatLiesAlongTheRouteIsInTheBriefing() {
        let path = SampleData.sampleLoop
        let onRoute = WorldObject(id: UUID(), kind: .chest, latitude: path[3].latitude, longitude: path[3].longitude, name: "Old chest", rewardAC: 25, expiresAt: t0)
        let off = GeoMath.destination(from: path[3], bearingDegrees: 270, distanceMeters: 900)
        let elsewhere = WorldObject(id: UUID(), kind: .monster, latitude: off.latitude, longitude: off.longitude, name: "Fen Troll", rewardAC: 60, expiresAt: t0)
        var taken = onRoute
        taken.id = UUID()
        taken.status = .claimed
        XCTAssertEqual(RideEvent.briefing(for: [onRoute, elsewhere, taken], along: path), .briefing(chests: 1, pieces: 0, monsters: []))
    }

    func testASightingSaysHowFarAndWhatItWants() {
        XCTAssertEqual(RideEvent.sighted(name: "Bog Wraith", kind: .monster, meters: 212, method: .pace).spoken(), "Bog Wraith, 200 metres. It wants a fast kilometre.")
        XCTAssertEqual(RideEvent.sighted(name: "Old chest", kind: .chest, meters: 140, method: nil).spoken(), "A chest, 150 metres.")
        XCTAssertEqual(RideEvent.sighted(name: "Raido", kind: .collectable, meters: 12, method: nil).spoken(), "A piece, 50 metres.")
    }

    func testAClaimSaysWhatItPaidAndAPieceSaysItsSet() {
        XCTAssertEqual(RideEvent.claimed(name: "Bog Wraith", kind: .monster, coins: 60, set: nil).spoken(), "Bog Wraith beaten. 60 coins.")
        XCTAssertEqual(RideEvent.claimed(name: "Old chest", kind: .chest, coins: 25, set: nil).spoken(), "Chest opened. 25 coins.")
        let third = RideEvent.claimed(name: "Raido", kind: .collectable, coins: 10, set: SetStanding(name: "Old Runes", owned: 3, of: 6))
        XCTAssertEqual(third.spoken(), "Raido. Old Runes, 3 of 6.")
        XCTAssertEqual(third.chime, .piece)
        let last = RideEvent.claimed(name: "Dagaz", kind: .collectable, coins: 10, set: SetStanding(name: "Old Runes", owned: 6, of: 6))
        XCTAssertEqual(last.spoken(), "Dagaz. Old Runes complete.")
        XCTAssertEqual(last.chime, .questDone, "a set made whole sounds like something finished")
    }

    func testAPieceAlreadyHeldDoesNotCountTwice() {
        var piece = SampleData.samplePiece
        piece.setName = "Old Runes"
        piece.setSize = 6
        piece.setOwned = 2
        XCTAssertEqual(piece.setStanding?.line, "Old Runes, 2 of 6")
        XCTAssertEqual(piece.setStandingOnceTaken?.line, "Old Runes, 3 of 6")
        piece.pieceOwned = true
        XCTAssertEqual(piece.setStandingOnceTaken?.line, "Old Runes, 2 of 6")
        XCTAssertNil(SampleData.sampleChest.setStandingOnceTaken)
    }

    func testObjectivesMilestonesAndHills() {
        XCTAssertEqual(RideEvent.objectiveCompleted(title: "Reach Old Station", remaining: 2).spoken(), "Objective done. Two left.")
        XCTAssertEqual(RideEvent.objectiveCompleted(title: "Reach Old Station", remaining: 0).spoken(), "Quest complete. Head home.")
        XCTAssertEqual(RideEvent.objectiveCompleted(title: "x", remaining: 0).chime, .questDone)
        XCTAssertEqual(RideEvent.milestone(.halfway, remainingMeters: 4200).pill(), "Halfway · 4.2 km to go")
        XCTAssertEqual(RideEvent.milestone(.lastKilometre, remainingMeters: 980).spoken(), "One kilometre to go.")
        XCTAssertEqual(RideEvent.hillAhead(lengthMeters: 640, gainMeters: 32).spoken(), "A hill ahead: 600 m.")
        XCTAssertEqual(RideEvent.hillTop.spoken(), "That was the worst of it.")
        XCTAssertNil(RideEvent.newGround(run: 3).spoken(), "new ground sings; it does not talk")
        XCTAssertEqual(RideEvent.newPlace(name: "Nunhead Reservoir").spoken(), "New place: Nunhead Reservoir.")
    }

    // MARK: Chimes

    func testNewGroundClimbsTheScaleAndStopsAtTheTop() {
        let first = RideEvent.newGround(run: 1), fourth = RideEvent.newGround(run: 4)
        XCTAssertEqual(first.chime, .newGround)
        let low = RideChime.newGround.notes(step: first.chimeStep)[0].frequency
        let higher = RideChime.newGround.notes(step: fourth.chimeStep)[0].frequency
        XCTAssertGreaterThan(higher, low)
        XCTAssertEqual(RideChime.newGround.notes(step: 99)[0].frequency, RideChime.scale.last)
        XCTAssertEqual(RideChime.scale, RideChime.scale.sorted())
    }

    func testEveryChimeIsShortAndAudible() {
        for chime in RideChime.allCases {
            let notes = chime.notes()
            XCTAssertFalse(notes.isEmpty, chime.rawValue)
            XCTAssertLessThan(chime.length(), 2.0, "\(chime.rawValue) goes on")
            for note in notes {
                XCTAssertTrue((100...2000).contains(note.frequency), chime.rawValue)
                XCTAssertTrue((0.05...1).contains(note.gain), chime.rawValue)
            }
        }
    }

    func testNewGroundRunStartsAgainAfterKnownRoads() {
        var run = NewGroundRun()
        XCTAssertEqual(run.entered(at: t0), 1)
        XCTAssertEqual(run.entered(at: t0.addingTimeInterval(40)), 2)
        XCTAssertEqual(run.entered(at: t0.addingTimeInterval(90)), 3)
        XCTAssertEqual(run.entered(at: t0.addingTimeInterval(90 + NewGroundRun.resetAfterSeconds + 1)), 1)
    }

    // MARK: The announcer

    func testLinesWaitTheirTurnAndTheWeightierGoFirst() {
        var announcer = RideAnnouncer(minimumGap: 4)
        announcer.offer(.milestone(.halfway, remainingMeters: 4000), at: t0)
        announcer.offer(.claimed(name: "Bog Wraith", kind: .monster, coins: 60, set: nil), at: t0.addingTimeInterval(1))
        XCTAssertEqual(announcer.nextLine(now: t0.addingTimeInterval(1)), "Bog Wraith beaten. 60 coins.")
        XCTAssertNil(announcer.nextLine(now: t0.addingTimeInterval(2)), "too soon after the last line")
        XCTAssertNil(announcer.nextLine(now: t0.addingTimeInterval(6), isSpeaking: true), "never over itself")
        XCTAssertEqual(announcer.nextLine(now: t0.addingTimeInterval(6)), "Halfway.")
        XCTAssertNil(announcer.nextLine(now: t0.addingTimeInterval(20)))
    }

    func testALineThatWaitedTooLongIsDroppedNotSaidLate() {
        var announcer = RideAnnouncer(minimumGap: 4)
        announcer.offer(.claimed(name: "Old chest", kind: .chest, coins: 25, set: nil), at: t0)
        announcer.offer(.sighted(name: "Fen Troll", kind: .monster, meters: 300, method: .climb), at: t0)
        XCTAssertEqual(announcer.nextLine(now: t0), "Chest opened. 25 coins.")
        // The troll was 300 m off a quarter of a minute ago; it is not there now.
        XCTAssertNil(announcer.nextLine(now: t0.addingTimeInterval(15)))
        XCTAssertEqual(announcer.waiting, 0)
    }

    func testOnlyTheLatestSightingWaits() {
        var announcer = RideAnnouncer()
        announcer.offer(.sighted(name: "Old chest", kind: .chest, meters: 350, method: nil), at: t0)
        announcer.offer(.sighted(name: "Fen Troll", kind: .monster, meters: 200, method: .pace), at: t0.addingTimeInterval(1))
        XCTAssertEqual(announcer.waiting, 1)
        XCTAssertEqual(announcer.nextLine(now: t0.addingTimeInterval(1)), "Fen Troll, 200 metres. It wants a fast kilometre.")
    }

    func testTheGapRunsFromTheEndOfALine() {
        var announcer = RideAnnouncer(minimumGap: 4)
        announcer.offer(.rerouted, at: t0)
        announcer.offer(.newPlace(name: "The Crown"), at: t0)
        XCTAssertEqual(announcer.nextLine(now: t0), "New route.")
        announcer.finishedSpeaking(at: t0.addingTimeInterval(3))
        XCTAssertNil(announcer.nextLine(now: t0.addingTimeInterval(5)))
        XCTAssertEqual(announcer.nextLine(now: t0.addingTimeInterval(7.5)), "New place: The Crown.")
    }

    // MARK: Milestones

    private func progress(along: Double, of total: Double, offRoute: Bool = false) -> ProgressUpdate {
        ProgressUpdate(
            distanceAlongRoute: along, distanceRemaining: max(0, total - along), nearestSegmentIndex: 0, crossTrackDistance: 0,
            snappedPosition: SampleData.origin, nextInstruction: nil, distanceToNextInstruction: nil, isOffRoute: offRoute,
            fractionComplete: min(1, along / total)
        )
    }

    func testEachMilestoneIsSaidOnce() {
        var milestones = RideMilestones(totalMeters: 10_000, climbs: [])
        XCTAssertEqual(milestones.update(progress: progress(along: 0, of: 10_000)), [], "the start of a loop is not its end")
        XCTAssertEqual(milestones.update(progress: progress(along: 4_900, of: 10_000)), [])
        XCTAssertEqual(milestones.update(progress: progress(along: 5_050, of: 10_000)), [.milestone(.halfway, remainingMeters: 4_950)])
        XCTAssertEqual(milestones.update(progress: progress(along: 5_500, of: 10_000)), [])
        XCTAssertEqual(milestones.update(progress: progress(along: 9_100, of: 10_000)), [.milestone(.lastKilometre, remainingMeters: 900)])
        XCTAssertEqual(milestones.update(progress: progress(along: 9_500, of: 10_000)), [])
        XCTAssertEqual(milestones.update(progress: progress(along: 9_980, of: 10_000)), [.milestone(.arrived, remainingMeters: 20)])
        XCTAssertEqual(milestones.update(progress: progress(along: 10_000, of: 10_000)), [])
    }

    func testNothingIsSaidOffTheRouteOrOnAShortOne() {
        var milestones = RideMilestones(totalMeters: 10_000, climbs: [])
        XCTAssertEqual(milestones.update(progress: progress(along: 5_050, of: 10_000, offRoute: true)), [])
        var short = RideMilestones(totalMeters: 1_200, climbs: [])
        XCTAssertEqual(short.update(progress: progress(along: 700, of: 1_200)), [])
    }

    func testAHillIsCalledBeforeItAndItsTopAfter() {
        let hill = Climb(startMeters: 3_000, lengthMeters: 600, gainMeters: 32, averageGradientPercent: 5.3)
        let bump = Climb(startMeters: 6_000, lengthMeters: 200, gainMeters: 6, averageGradientPercent: 3)
        var milestones = RideMilestones(totalMeters: 20_000, climbs: [hill, bump])
        XCTAssertEqual(milestones.update(progress: progress(along: 2_500, of: 20_000)), [])
        XCTAssertEqual(milestones.update(progress: progress(along: 2_850, of: 20_000)), [.hillAhead(lengthMeters: 600, gainMeters: 32)])
        XCTAssertEqual(milestones.update(progress: progress(along: 3_300, of: 20_000)), [])
        XCTAssertEqual(milestones.update(progress: progress(along: 3_620, of: 20_000)), [.hillTop])
        XCTAssertEqual(milestones.update(progress: progress(along: 5_900, of: 20_000)), [], "a six-metre rise is not a hill")

        // A hill joined half-way up is not announced as "ahead", so it has no top to mark either.
        var late = RideMilestones(totalMeters: 20_000, climbs: [hill])
        XCTAssertEqual(late.update(progress: progress(along: 3_400, of: 20_000)), [])
        XCTAssertEqual(late.update(progress: progress(along: 3_700, of: 20_000)), [])
    }

    // MARK: The reckoning's words

    func testANearMissIsToldAsANearThing() {
        let troll = MissedObject(
            id: UUID(), kind: .monster, name: "The Fen Troll", reason: "UNBEATEN", expiresAt: t0.addingTimeInterval(2.4 * 86_400),
            attempt: MissedAttempt(method: .pace, progress: 0.94, paceSecPerKm: 138, targetSecPerKm: 130, windowMeters: 1000)
        )
        XCTAssertEqual(RewardCopy.shruggedOff(troll, now: t0), "The Fen Troll shrugged it off. You gave it 2:18 a kilometre; it wanted 2:10. It is there two more days.")
        let climb = MissedAttempt(method: .climb, gainMeters: 28, targetGainMeters: 40)
        XCTAssertEqual(RewardCopy.nearMiss(climb), "You climbed 28 m beside it; it wanted 40 m.")
        XCTAssertEqual(RewardCopy.nearMiss(MissedAttempt(method: .explore, cells: 1, targetCells: 3)), "You cleared 1 new area round it; it wanted 3.")
        XCTAssertNil(RewardCopy.nearMiss(MissedAttempt(method: .lore)))
        XCTAssertEqual(RewardCopy.staying(until: t0.addingTimeInterval(3_600), now: t0), "It is gone tonight.")
        // An older server says only that it got away.
        XCTAssertEqual(RewardCopy.shruggedOff(MissedObject(id: UUID(), kind: .monster, name: "Mire Hag", reason: "UNBEATEN")), "Mire Hag shrugged it off.")
    }

    func testBreakdownLinesHaveWords() {
        XCTAssertEqual(RewardCopy.xp(source: "KNOWN_GROUND"), "Known ground")
        XCTAssertEqual(RewardCopy.xp(source: "CLASS_BONUS", className: "Explorer"), "Explorer bonus")
        XCTAssertEqual(RewardCopy.xp(source: "SOMETHING_NEW"), "Something new")
        XCTAssertEqual(RewardCopy.coins(kind: "RIDE_DISTANCE"), "The distance")
        XCTAssertEqual(RewardCopy.coins(kind: "STORY_ARC"), "An arc finished")
    }

    // MARK: Turns on the wrist

    func testATurnIsCuedAsItComesUpAndAgainWhenItIsHere() {
        var cues = TurnCueTracker()
        let left = Instruction(index: 3, text: "Turn left", streetName: "Mill Road", sign: .left, distanceMeters: 400, durationSeconds: 60, coordinateIndex: 30, latitude: 51.5, longitude: -0.04)
        XCTAssertNil(cues.update(instruction: left, distanceMeters: 380))
        XCTAssertEqual(cues.update(instruction: left, distanceMeters: 140), .approaching(.left))
        XCTAssertNil(cues.update(instruction: left, distanceMeters: 90), "once is enough")
        XCTAssertEqual(cues.update(instruction: left, distanceMeters: 30), .now(.left))
        XCTAssertNil(cues.update(instruction: left, distanceMeters: 10))

        // Carrying on, and arriving, are not turns.
        let straight = Instruction(index: 4, text: "Continue", streetName: "Mill Road", sign: .continue, distanceMeters: 300, durationSeconds: 40, coordinateIndex: 40, latitude: 51.5, longitude: -0.04)
        XCTAssertNil(cues.update(instruction: straight, distanceMeters: 20))
        XCTAssertNil(cues.update(instruction: nil, distanceMeters: nil))

        // A turn joined at the turn gets the one cue that matters.
        let right = Instruction(index: 5, text: "Turn right", streetName: "River Path", sign: .sharpRight, distanceMeters: 60, durationSeconds: 10, coordinateIndex: 50, latitude: 51.5, longitude: -0.04)
        XCTAssertEqual(cues.update(instruction: right, distanceMeters: 20), .now(.right))
        XCTAssertNil(cues.update(instruction: right, distanceMeters: 100))

        cues.reset()
        XCTAssertEqual(cues.update(instruction: left, distanceMeters: 120), .approaching(.left), "a new route numbers its turns again")
    }

    // MARK: Reminders

    func testAReminderNamesWhatIsThereOrSaysNothingOfIt() {
        let home = SampleData.origin
        func thing(_ kind: WorldObjectKind, _ name: String, meters: Double, bounty: Bool = false, hours: Double = 48) -> WorldObject {
            let at = GeoMath.destination(from: home, bearingDegrees: 40, distanceMeters: meters)
            return WorldObject(id: UUID(), kind: kind, latitude: at.latitude, longitude: at.longitude, name: name, bounty: bounty, rewardAC: 60, expiresAt: t0.addingTimeInterval(hours * 3600))
        }
        let evening = t0.addingTimeInterval(4 * 3600)
        let drake = thing(.monster, "Gutter Drake", meters: 900, bounty: true, hours: 9)
        let chest = thing(.chest, "Old chest", meters: 400)
        let gone = thing(.chest, "Iron chest", meters: 100, hours: 2)

        var lures = NudgeCopy.lures(among: [drake, chest, gone], from: home, stillThereAt: evening)
        XCTAssertEqual(lures.bounty?.name, "Gutter Drake")
        XCTAssertEqual(lures.nearest?.name, "Old chest", "the nearer chest will have gone by the evening")
        let withBounty = NudgeCopy.streak(days: 6, activity: .ride, bounty: lures.bounty, nearest: lures.nearest)
        XCTAssertEqual(withBounty.title, "6 days kept. Today not yet.")
        XCTAssertEqual(withBounty.body, "The Gutter Drake is 900 m away and worth double till midnight. One kilometre keeps the days.")

        lures = NudgeCopy.lures(among: [chest], from: home, stillThereAt: evening)
        XCTAssertEqual(NudgeCopy.streak(days: 3, activity: .walk, bounty: lures.bounty, nearest: lures.nearest).body, "One kilometre keeps it alive. An Old chest is 400 m away.")

        // Nothing near: nothing is promised.
        lures = NudgeCopy.lures(among: [thing(.chest, "Old chest", meters: 9000)], from: home, stillThereAt: evening)
        XCTAssertNil(lures.nearest)
        XCTAssertEqual(NudgeCopy.streak(days: 3, activity: .run, bounty: nil, nearest: nil).body, "One kilometre keeps it alive. A short run will do.")
        XCTAssertFalse(NudgeCopy.bountyMorning().body.contains("closer"))
    }
}
