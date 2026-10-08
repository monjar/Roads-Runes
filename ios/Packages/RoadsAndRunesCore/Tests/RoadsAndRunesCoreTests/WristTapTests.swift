import XCTest
@testable import RoadsAndRunesCore

/// A fight must never say anything a turn says (docs/ROADMAP.md, 0.6.1).
final class WristTapTests: XCTestCase {
    func testFightTapsNeverShareAPatternWithTurnTaps() {
        XCTAssertTrue(WristTap.fight.isDisjoint(with: WristTap.turns))
        XCTAssertEqual(WristTap.fight.union(WristTap.turns), Set(WristTap.allCases))
        for beat in FightBeat.allCases {
            XCTAssertTrue(WristTap.fight.contains(beat.tap), beat.rawValue)
        }
    }

    func testAFightIsQuietWhileATurnIsClose() {
        XCTAssertFalse(TurnWindow.isClear(distanceToInstructionMeters: 80))
        XCTAssertFalse(TurnWindow.isClear(distanceToInstructionMeters: TurnCueTracker.approachMeters))
        XCTAssertTrue(TurnWindow.isClear(distanceToInstructionMeters: 400))
        XCTAssertTrue(TurnWindow.isClear(distanceToInstructionMeters: nil), "no route, no turn to keep clear of")
    }

    func testStillMeansSlowForFiveSecondsAndUnknownMeansMoving() {
        var still = Stillness()
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(still.update(speedMps: 0.2, at: t0))
        XCTAssertFalse(still.update(speedMps: 0.3, at: t0.addingTimeInterval(4)))
        XCTAssertTrue(still.update(speedMps: 0.1, at: t0.addingTimeInterval(5)))
        XCTAssertFalse(still.update(speedMps: nil, at: t0.addingTimeInterval(6)), "an unknown speed is moving")
        XCTAssertFalse(still.update(speedMps: 0, at: t0.addingTimeInterval(7)), "the five seconds start again")
        XCTAssertFalse(still.update(speedMps: 3, at: t0.addingTimeInterval(20)))
        XCTAssertFalse(still.update(speedMps: -1, at: t0.addingTimeInterval(21)), "an invalid speed is moving")
    }

    func testTheBeatRoundTripsAndAnOlderPhoneStillDecodes() throws {
        let beat = WatchEncounterBeat(beat: .engaged, name: "Fen Troll")
        let message = try WatchMessages.encounterBeat(beat)
        XCTAssertEqual(WatchMessages.kind(of: message), .encounterBeat)
        XCTAssertEqual(try WatchMessages.encounterBeat(from: message), beat)

        let old = WatchObjectiveCompleted(title: "Fen Troll", coins: 60)
        let decoded = try WatchMessages.objectiveCompleted(from: WatchMessages.objectiveCompleted(old))
        XCTAssertNil(decoded.outcome)
    }
}
