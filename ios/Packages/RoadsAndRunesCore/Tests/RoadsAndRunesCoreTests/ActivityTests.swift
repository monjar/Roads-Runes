import Foundation
import XCTest
@testable import RoadsAndRunesCore

final class ActivityTests: XCTestCase {
    func testActivitiesHaveWordsAndDecodeLeniently() throws {
        XCTAssertEqual(Activity.run.verb, "Run")
        XCTAssertEqual(Activity.walk.noun, "walk")
        XCTAssertEqual(Activity.ride.symbol, "bicycle")
        XCTAssertEqual(try JSONDecoder().decode([Activity].self, from: Data(#"["RUN","SWIM"]"#.utf8)), [.run, .unknown])
    }

    /// A Watch that predates activities still reads the phone's summary, and a phone
    /// that predates them still reads a server ride.
    func testPayloadsWithoutAnActivityStillDecode() throws {
        let summary = try JSONDecoder().decode(
            WatchRouteSummary.self,
            from: Data(#"{"instructions":[],"objectives":[],"totalDistanceMeters":1200,"routeCoordinates":[],"stops":[]}"#.utf8)
        )
        XCTAssertNil(summary.activity)
        let create = RideCreate(clientRideId: UUID(), startedAt: Date(), activity: .walk)
        let encoded = try JSONCoding.encode(create)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains(#""activity":"WALK""#))
    }
}
