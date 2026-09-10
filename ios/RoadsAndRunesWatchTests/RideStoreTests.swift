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
}
