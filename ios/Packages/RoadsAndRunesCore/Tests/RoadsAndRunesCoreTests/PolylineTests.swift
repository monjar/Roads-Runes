import XCTest
@testable import RoadsAndRunesCore

final class PolylineTests: XCTestCase {
    func testGoogleReferenceVector() {
        let decoded = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].latitude, 38.5, accuracy: 1e-5)
        XCTAssertEqual(decoded[0].longitude, -120.2, accuracy: 1e-5)
        XCTAssertEqual(decoded[1].latitude, 40.7, accuracy: 1e-5)
        XCTAssertEqual(decoded[1].longitude, -120.95, accuracy: 1e-5)
        XCTAssertEqual(decoded[2].latitude, 43.252, accuracy: 1e-5)
        XCTAssertEqual(decoded[2].longitude, -126.453, accuracy: 1e-5)
        XCTAssertEqual(Polyline.encode(decoded), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    }

    func testRoundTrip() {
        let loop = SampleData.squareLoop(center: SampleData.origin, sideMeters: 800, pointsPerSide: 7)
        let encoded = Polyline.encode(loop)
        let decoded = Polyline.decode(encoded)
        XCTAssertEqual(decoded.count, loop.count)
        for (a, b) in zip(loop, decoded) {
            XCTAssertEqual(a.latitude, b.latitude, accuracy: 1e-5)
            XCTAssertEqual(a.longitude, b.longitude, accuracy: 1e-5)
        }
        XCTAssertEqual(Polyline.decode(""), [])
        XCTAssertEqual(Polyline.encode([]), "")
    }

    func testSampleRoutePolylineMatchesCoordinates() {
        let decoded = Polyline.decode(SampleData.sampleRoute.encodedPolyline)
        XCTAssertEqual(decoded.count, SampleData.sampleRoute.coordinates.count)
        XCTAssertEqual(decoded.first?.latitude ?? 0, SampleData.sampleRoute.coordinates[0][1], accuracy: 1e-5)
    }
}
