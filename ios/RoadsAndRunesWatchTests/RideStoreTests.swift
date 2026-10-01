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
}
