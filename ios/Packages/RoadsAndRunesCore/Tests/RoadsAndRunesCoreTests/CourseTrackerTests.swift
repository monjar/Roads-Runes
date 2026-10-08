@testable import RoadsAndRunesCore
import XCTest

final class CourseTrackerTests: XCTestCase {
    private let start = Coordinate(latitude: 51.49, longitude: -0.04)

    private func moved(_ from: Coordinate, metersNorth: Double = 0, metersEast: Double = 0) -> Coordinate {
        Coordinate(
            latitude: from.latitude + metersNorth / 111_320,
            longitude: from.longitude + metersEast / (111_320 * cos(from.latitude * .pi / 180))
        )
    }

    func testThereIsNoCourseBeforeTheRiderMoves() {
        var tracker = CourseTracker()
        XCTAssertNil(tracker.update(start))
        XCTAssertNil(tracker.update(moved(start, metersNorth: 1)), "a metre of GPS noise is not a direction")
    }

    func testMovingEastPointsEastAndNorthPointsNorth() throws {
        var tracker = CourseTracker()
        tracker.update(start)
        let east = try XCTUnwrap(tracker.update(moved(start, metersEast: 10)))
        XCTAssertEqual(east, 90, accuracy: 1)
        let north = try XCTUnwrap(tracker.update(moved(moved(start, metersEast: 10), metersNorth: 10)))
        XCTAssertEqual(north, 0, accuracy: 1)
    }

    func testStandingStillKeepsTheLastCourse() throws {
        var tracker = CourseTracker()
        tracker.update(start)
        let east = moved(start, metersEast: 12)
        tracker.update(east)
        // Jitter round a stop does not turn the arrow.
        XCTAssertEqual(try XCTUnwrap(tracker.update(moved(east, metersNorth: 1.5))), 90, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(tracker.update(moved(east, metersNorth: -1.5))), 90, accuracy: 1)
    }

    func testSmallStepsAddUpToADirection() throws {
        var tracker = CourseTracker()
        tracker.update(start)
        var here = moved(start, metersNorth: -2.5)
        XCTAssertNil(tracker.update(here), "2.5 m is not yet a direction")
        here = moved(here, metersNorth: -2.5)
        // 5 m from where it last knew: now it is.
        XCTAssertEqual(try XCTUnwrap(tracker.update(here)), 180, accuracy: 1)
    }
}
