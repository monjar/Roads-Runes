import XCTest
@testable import RoadsAndRunesCore

final class NavigationStateMachineTests: XCTestCase {
    func testHappyPath() throws {
        var machine = NavigationStateMachine()
        XCTAssertEqual(machine.state, .preparing)
        try machine.transition(to: .ready)
        try machine.transition(to: .active)
        try machine.transition(to: .offRoute)
        try machine.transition(to: .rerouting)
        try machine.transition(to: .active)
        try machine.transition(to: .paused)
        try machine.transition(to: .active)
        try machine.transition(to: .finishing)
        try machine.transition(to: .completed)
        XCTAssertEqual(machine.state, .completed)
        XCTAssertEqual(machine.previousState, .finishing)
        XCTAssertTrue(machine.state.isTerminal)
    }

    func testIllegalTransitionsThrow() {
        var machine = NavigationStateMachine()
        XCTAssertThrowsError(try machine.transition(to: .active)) { error in
            XCTAssertEqual(error as? NavigationTransitionError, NavigationTransitionError(from: .preparing, to: .active))
        }
        XCTAssertEqual(machine.state, .preparing)

        var active = NavigationStateMachine(state: .active)
        XCTAssertThrowsError(try active.transition(to: .completed))
        XCTAssertThrowsError(try active.transition(to: .rerouting))
        XCTAssertThrowsError(try active.transition(to: .ready))

        var rerouting = NavigationStateMachine(state: .rerouting)
        XCTAssertThrowsError(try rerouting.transition(to: .paused))

        var done = NavigationStateMachine(state: .completed)
        XCTAssertThrowsError(try done.transition(to: .active))
        var cancelled = NavigationStateMachine(state: .cancelled)
        XCTAssertThrowsError(try cancelled.transition(to: .ready))
        XCTAssertFalse(cancelled.transitionIfPossible(to: .active))
    }

    func testEveryStateCanCancelExceptTerminal() {
        for state in NavigationState.allCases where !state.isTerminal {
            XCTAssertTrue(state.canTransition(to: .cancelled), state.rawValue)
        }
    }

    func testRecoveryEdges() throws {
        var machine = NavigationStateMachine(state: .recovery)
        XCTAssertTrue(machine.canTransition(to: .active))
        XCTAssertTrue(machine.canTransition(to: .paused))
        XCTAssertTrue(machine.canTransition(to: .finishing))
        XCTAssertFalse(machine.canTransition(to: .ready))
        try machine.transition(to: .finishing)
        try machine.transition(to: .completed)
    }
}
