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
