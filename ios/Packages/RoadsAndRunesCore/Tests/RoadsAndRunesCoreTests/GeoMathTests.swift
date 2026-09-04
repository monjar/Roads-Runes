import XCTest
@testable import RoadsAndRunesCore

final class GeoMathTests: XCTestCase {
    func testDistanceAndBearing() {
        let a = Coordinate(latitude: 51.49, longitude: -0.04)
        let b = GeoMath.destination(from: a, bearingDegrees: 90, distanceMeters: 1000)
        XCTAssertEqual(GeoMath.distance(a, b), 1000, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearing(from: a, to: b), 90, accuracy: 0.05)
        let north = GeoMath.destination(from: a, bearingDegrees: 0, distanceMeters: 500)
        XCTAssertEqual(GeoMath.bearing(from: a, to: north), 0, accuracy: 0.01)
        XCTAssertEqual(GeoMath.bearingDelta(from: 350, to: 10), 20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.bearingDelta(from: 10, to: 350), -20, accuracy: 1e-9)
    }

    func testSegmentProjection() {
        let a = Coordinate(latitude: 51.49, longitude: -0.04)
        let b = GeoMath.destination(from: a, bearingDegrees: 90, distanceMeters: 400)
        let mid = GeoMath.destination(from: a, bearingDegrees: 90, distanceMeters: 200)
        let offset = GeoMath.destination(from: mid, bearingDegrees: 0, distanceMeters: 30)
        let projection = GeoMath.project(offset, ontoSegment: a, b)
        XCTAssertEqual(projection.distanceMeters, 30, accuracy: 0.5)
        XCTAssertEqual(projection.fraction, 0.5, accuracy: 0.01)
        XCTAssertEqual(GeoMath.distance(projection.point, mid), 0, accuracy: 0.5)

        let beyond = GeoMath.destination(from: b, bearingDegrees: 90, distanceMeters: 100)
        let clamped = GeoMath.project(beyond, ontoSegment: a, b)
        XCTAssertEqual(clamped.fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(clamped.distanceMeters, 100, accuracy: 0.5)
    }

    func testCumulativeDistances() {
        let loop = SampleData.squareLoop(center: SampleData.origin, sideMeters: 600, pointsPerSide: 5)
        let cumulative = GeoMath.cumulativeDistances(loop)
        XCTAssertEqual(cumulative.count, loop.count)
        XCTAssertEqual(cumulative.first, 0)
        XCTAssertEqual(cumulative.last ?? 0, 2400, accuracy: 5)
        XCTAssertEqual(GeoMath.pathLength(loop), cumulative.last ?? -1, accuracy: 1e-6)
    }
}
