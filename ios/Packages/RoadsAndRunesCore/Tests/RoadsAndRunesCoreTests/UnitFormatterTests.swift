import XCTest
@testable import RoadsAndRunesCore

final class UnitFormatterTests: XCTestCase {
    func testMetric() {
        let f = UnitFormatter(units: .metric)
        XCTAssertEqual(f.distance(meters: 180), "180 m")
        XCTAssertEqual(f.distance(meters: 999.4), "999 m")
        XCTAssertEqual(f.distance(meters: 12600), "12.6 km")
        XCTAssertEqual(f.distance(meters: 123_456), "123 km")
        XCTAssertEqual(f.elevation(meters: 340.4), "340 m")
        XCTAssertEqual(f.speed(metersPerSecond: 4.3), "15.5 km/h")
        XCTAssertEqual(f.distanceUnitLabel, "km")
        XCTAssertEqual(f.speedUnitLabel, "km/h")
    }

    func testImperial() {
        let f = UnitFormatter(units: .imperial)
        XCTAssertEqual(f.distance(meters: 100), "328 ft")
        XCTAssertEqual(f.distance(meters: 12600), "7.8 mi")
        XCTAssertEqual(f.distance(meters: 200_000), "124 mi")
        XCTAssertEqual(f.elevation(meters: 340), "1115 ft")
        XCTAssertEqual(f.speed(metersPerSecond: 4.3), "9.6 mph")
        XCTAssertEqual(f.speedUnitLabel, "mph")
        XCTAssertTrue(f.isImperial)
    }

    func testDuration() {
        let f = UnitFormatter(units: .metric)
        XCTAssertEqual(f.duration(seconds: 7440), "2h 04m")
        XCTAssertEqual(f.duration(seconds: 3600), "1h 00m")
        XCTAssertEqual(f.duration(seconds: 2040), "34 min")
        XCTAssertEqual(f.duration(seconds: 45), "45 s")
        XCTAssertEqual(f.duration(seconds: -5), "0 s")
    }

    func testUnknownUnitsBehaveAsMetric() {
        let f = UnitFormatter(units: .unknown)
        XCTAssertEqual(f.distance(meters: 1500), "1.5 km")
    }
}
