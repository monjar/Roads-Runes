import XCTest
@testable import RoadsAndRunesCore

final class InkFogTests: XCTestCase {
    private let square = [
        Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 1),
        Coordinate(latitude: 1, longitude: 1), Coordinate(latitude: 1, longitude: 0), Coordinate(latitude: 0, longitude: 0),
    ]

    func testSofteningCutsEveryCornerAndStaysInside() {
        let soft = InkFog.soften(square, passes: 2)
        XCTAssertEqual(soft.count, 4 * 4 + 1, "each pass doubles the corners; the ring closes")
        XCTAssertEqual(soft.first, soft.last)
        XCTAssertFalse(soft.contains(Coordinate(latitude: 0, longitude: 0)), "the corner is gone")
        for p in soft { XCTAssertTrue((0...1).contains(p.latitude) && (0...1).contains(p.longitude)) }
    }

    func testTheWashIsTheBoundsWithTheReadGroundCutOut() {
        let bounds = BoundingBox(minLat: -1, minLon: -1, maxLat: 2, maxLon: 2)
        let far = square.map { Coordinate(latitude: $0.latitude + 10, longitude: $0.longitude) }
        let wash = InkFog.wash(bounds: bounds, outlines: [square, far])
        XCTAssertEqual(wash.count, 2, "the outer ring and one hole; the outline off the map is left out")
        XCTAssertEqual(wash[0].count, 5)
    }

    func testTheNearestUnreadGroundIsBesideTheReadGround() {
        let indexing = FakeCellIndexing()
        let here = Coordinate(latitude: 51.4906, longitude: -0.0316)
        let cell = indexing.cell(latitude: here.latitude, longitude: here.longitude, resolution: 9)
        let target = try? XCTUnwrap(InkFog.nearestUnread(from: here, read: [cell], indexing: indexing))
        XCTAssertNotNil(target)
        XCTAssertNotEqual(indexing.cell(latitude: target!.latitude, longitude: target!.longitude, resolution: 9), cell)
        XCTAssertNil(InkFog.nearestUnread(from: here, read: [], indexing: indexing))
    }
}
