import Foundation
import XCTest
@testable import RoadsAndRunesCore

final class RideActivityStateTests: XCTestCase {
    private let turn = Instruction(
        index: 3, text: "Turn left onto Mill Lane", streetName: "Mill Lane", sign: .left, distanceMeters: 400,
        durationSeconds: 60, coordinateIndex: 12, latitude: 51.5, longitude: -0.1
    )
    private let fight = WatchFight(speciesId: "fen-troll", name: "Fen Troll", icon: "troll", tenthsLeft: 7, quarry: true, defeated: false)

    func testFromANavigationUpdate() {
        let update = WatchNavigationUpdate(
            state: .active, instruction: turn, distanceToInstructionMeters: 180, distanceMeters: 4_250, elapsedSeconds: 900,
            elevationGainMeters: 40, encounterLine: "Fen Troll · 120 m", fight: fight
        )
        let state = RideActivityState(update: update)
        XCTAssertEqual(state.instructionText, "Turn left onto Mill Lane")
        XCTAssertEqual(state.maneuver, "LEFT")
        XCTAssertEqual(state.sign, .left)
        XCTAssertEqual(state.distanceToTurnMeters, 180)
        XCTAssertEqual(state.distanceMeters, 4_250)
        XCTAssertEqual(state.quarryIcon, "troll")
        XCTAssertEqual(state.quarryTenthsLeft, 7)
        XCTAssertEqual(state.quarryFraction, 0.7, accuracy: 0.0001)
        XCTAssertTrue(state.showsQuarry)
        XCTAssertFalse(state.paused)
        XCTAssertEqual(RideActivityState.symbol(for: state.sign), "arrow.turn.up.left")
    }

    func testPausedHidesTheTurnAndKeepsTheRing() {
        let state = RideActivityState(state: .paused, instruction: turn, distanceToTurnMeters: 180, distanceMeters: 4_250, fight: fight)
        XCTAssertTrue(state.paused)
        XCTAssertNil(state.instructionText)
        XCTAssertNil(state.maneuver)
        XCTAssertNil(state.distanceToTurnMeters)
        XCTAssertEqual(state.quarryTenthsLeft, 7)
    }

    func testAFreeJourneyHasNoTurnAndNoFight() {
        let state = RideActivityState(state: .active, instruction: nil, distanceToTurnMeters: nil, distanceMeters: -3, fight: nil)
        XCTAssertNil(state.maneuver)
        XCTAssertEqual(state.distanceMeters, 0)
        XCTAssertFalse(state.showsQuarry)
        XCTAssertEqual(RideActivityState.symbol(for: state.sign), "arrow.up")
        XCTAssertEqual(RideActivityState.phrase(for: nil), "Continue")
    }

    func testTenthsAreClamped() {
        XCTAssertEqual(RideActivityState(quarryTenthsLeft: 14).quarryTenthsLeft, 10)
        XCTAssertEqual(RideActivityState(quarryTenthsLeft: -2).quarryTenthsLeft, 0)
    }

    func testContentStateRoundTrips() throws {
        let state = RideActivityState(instructionText: "Bear right", maneuver: "SLIGHT_RIGHT", distanceToTurnMeters: 90,
                                      distanceMeters: 1200, quarryIcon: "troll", quarryTenthsLeft: 3, paused: false)
        XCTAssertEqual(try JSONDecoder().decode(RideActivityState.self, from: JSONEncoder().encode(state)), state)
    }

    func testThrottleSendsEveryFiveSecondsOrOnATurn() {
        var throttle = RideActivityThrottle()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var state = RideActivityState(instructionText: "Turn left", maneuver: "LEFT", distanceToTurnMeters: 300, distanceMeters: 100)
        XCTAssertTrue(throttle.shouldSend(state, at: t0))

        // Nearer the same turn: not yet.
        state.distanceToTurnMeters = 250
        state.distanceMeters = 150
        XCTAssertFalse(throttle.shouldSend(state, at: t0.addingTimeInterval(2)))
        // Five seconds on: yes.
        XCTAssertTrue(throttle.shouldSend(state, at: t0.addingTimeInterval(5)))
        // Nothing changed at all: never.
        XCTAssertFalse(throttle.shouldSend(state, at: t0.addingTimeInterval(60)))

        // A new turn goes at once.
        state.maneuver = "RIGHT"
        state.instructionText = "Turn right"
        XCTAssertTrue(throttle.shouldSend(state, at: t0.addingTimeInterval(61)))
        // A pause goes at once.
        state.paused = true
        XCTAssertTrue(throttle.shouldSend(state, at: t0.addingTimeInterval(61.5)))
        // The ring losing a tick goes at once.
        state.quarryIcon = "troll"
        state.quarryTenthsLeft = 6
        XCTAssertTrue(throttle.shouldSend(state, at: t0.addingTimeInterval(62)))
        state.quarryTenthsLeft = 5
        XCTAssertTrue(throttle.shouldSend(state, at: t0.addingTimeInterval(62.5)))

        throttle.reset()
        XCTAssertNil(throttle.lastSent)
        XCTAssertTrue(throttle.shouldSend(state, at: t0.addingTimeInterval(63)))
    }
}
