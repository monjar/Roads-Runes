import XCTest
@testable import RoadsAndRunesCore

/// Ride anywhere (0.9.2): a journey with no route, the world refreshed round it as
/// it goes, and the quests it finishes on the way.
final class RideAnywhereTests: XCTestCase {
    // MARK: - Quests where they fit

    func testJourneysEndSaysTheQuestFinishedOnTheWay() throws {
        let decoder = JSONCoding.makeDecoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AdventureSummaryDecodingTests.json.utf8)) as? [String: Any])
        json["quest"] = NSNull()
        json["alsoFinished"] = ["id": "8a1f0b2c-0000-4000-8000-00000000c001", "title": "Ten Miles Out"]
        let summary = try decoder.decode(AdventureSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(summary.alsoFinished, AlsoFinishedQuest(id: "8a1f0b2c-0000-4000-8000-00000000c001", title: "Ten Miles Out"))
        XCTAssertNil(summary.quest)
        XCTAssertEqual(LoreCopy.alsoFinished("Ten Miles Out"), "Also finished: Ten Miles Out")

        // A server from before 0.9.2 sends none.
        let before = try decoder.decode(AdventureSummary.self, from: Data(AdventureSummaryDecodingTests.json.utf8))
        XCTAssertNil(before.alsoFinished)
    }

    // MARK: - The Watch and recovery

    func testARoamsSummaryIsEmptyButForTheWorldAndAnOlderWatchStillReadsIt() throws {
        let start = Coordinate(latitude: 51.49, longitude: -0.04)
        let chest = WorldObject(id: UUID(), kind: .chest, latitude: 51.495, longitude: -0.04, name: "Old chest", rewardAC: 25,
                                expiresAt: Date().addingTimeInterval(86_400))
        let far = WorldObject(id: UUID(), kind: .chest, latitude: 51.53, longitude: -0.04, name: "Far chest", rewardAC: 25,
                              expiresAt: Date().addingTimeInterval(86_400))
        // No route: things within 2 km of the rider.
        let marks = WatchWorldMarks.select(objects: [chest, far], route: [], start: start)
        XCTAssertEqual(marks.map(\.id), [chest.id])

        let summary = WatchRouteSummary.roaming(activity: .run, worldMarks: marks)
        XCTAssertTrue(summary.isRoam)
        XCTAssertEqual(summary.roam, true)
        XCTAssertTrue(summary.instructions.isEmpty && summary.routeCoordinates.isEmpty && summary.objectives.isEmpty)
        let data = try JSONCoding.encode(summary)
        let back = try JSONCoding.makeDecoder().decode(WatchRouteSummary.self, from: data)
        XCTAssertEqual(back, summary)

        // A Watch from before 0.9.2 reads it as a summary with no route (its own no-route face).
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["roam"] as? Bool, true)
        json.removeValue(forKey: "roam")
        let older = try JSONCoding.makeDecoder().decode(WatchRouteSummary.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.roam)
        XCTAssertTrue(older.isRoam, "no turns and no line is no route to follow")
        XCTAssertEqual(older.worldMarks?.map(\.id), [chest.id])
    }

    func testARoamIsRememberedThroughACrash() throws {
        let state = ActiveRideState(clientRideId: UUID(), navigationState: .active, startedAt: Date(), updatedAt: Date(),
                                    stats: RideSnapshot(), visitedCells: ["89194ad1fffffff"], roam: true)
        let back = try JSONCoding.makeDecoder().decode(ActiveRideState.self, from: JSONCoding.encode(state))
        XCTAssertTrue(back.isRoam)
        XCTAssertNil(back.routeId)
        // A snapshot from before 0.9.2 is a planned ride.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.encode(state)) as? [String: Any])
        json.removeValue(forKey: "roam")
        let older = try JSONCoding.makeDecoder().decode(ActiveRideState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(older.isRoam)
    }

    func testTheButtonSaysTheActivity() {
        XCTAssertEqual(LoreCopy.anywhere(.ride), "Ride anywhere")
        XCTAssertEqual(LoreCopy.anywhere(.run), "Run anywhere")
        XCTAssertEqual(LoreCopy.anywhere(.walk), "Walk anywhere")
        XCTAssertEqual(LoreCopy.anywhere(nil), "Ride anywhere")
        XCTAssertEqual(LoreCopy.stillOut(.ride), "Still out? End ride or keep going.")
        XCTAssertEqual(LoreCopy.stillOut(.walk), "Still out? End walk or keep going.")
        XCTAssertLessThanOrEqual(LoreCopy.anywhere(.walk).split(separator: " ").count, 3)
    }
}
