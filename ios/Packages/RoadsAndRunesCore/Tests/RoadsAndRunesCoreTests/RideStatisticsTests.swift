import XCTest
@testable import RoadsAndRunesCore

final class RideStatisticsTests: XCTestCase {
    private let start = SampleData.origin
    private let t0 = SampleData.referenceDate

    private func fix(seconds: Double, metersNorth: Double, altitude: Double? = nil, accuracy: Double? = 5, speed: Double? = nil, heartRate: Int? = nil) -> LocationFix {
        LocationFix(
            coordinate: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: metersNorth),
            timestamp: t0.addingTimeInterval(seconds), altitude: altitude, horizontalAccuracy: accuracy, speed: speed, heartRate: heartRate
        )
    }

    func testDistanceMovingTimeAndSpeeds() {
        var stats = RideStatistics()
        for i in 0...9 {
            stats.add(fix: LocationFix(
                coordinate: GeoMath.destination(from: start, bearingDegrees: 0, distanceMeters: Double(i) * 10),
                timestamp: t0.addingTimeInterval(Double(i)), altitude: nil, horizontalAccuracy: 5, speed: nil, heartRate: 120 + i
            ))
        }
        XCTAssertEqual(stats.distanceMeters, 90, accuracy: 0.5)
        XCTAssertEqual(stats.movingSeconds, 9, accuracy: 1e-9)
        XCTAssertEqual(stats.elapsedSeconds, 9, accuracy: 1e-9)
        XCTAssertEqual(stats.averageSpeedMps, 10, accuracy: 0.1)
        XCTAssertEqual(stats.maxSpeedMps, 10, accuracy: 0.1)
        XCTAssertEqual(stats.currentSpeedMps, 10, accuracy: 0.1)
        XCTAssertEqual(stats.lastHeartRateBpm, 129)
        XCTAssertEqual(stats.averageHeartRateBpm ?? 0, 124.5, accuracy: 1e-9)
        XCTAssertEqual(stats.acceptedFixCount, 10)

        // Standing still for 20 s with a reported speed of 0 does not count as moving.
        stats.add(fix: fix(seconds: 29, metersNorth: 90, speed: 0))
        XCTAssertEqual(stats.movingSeconds, 9, accuracy: 1e-9)
        XCTAssertEqual(stats.elapsedSeconds, 29, accuracy: 1e-9)
        XCTAssertEqual(stats.currentSpeedMps, 0)
    }

    func testImplausibleAndInaccurateFixesAreIgnored() {
        var stats = RideStatistics()
        stats.add(fix: fix(seconds: 0, metersNorth: 0))
        stats.add(fix: fix(seconds: 1, metersNorth: 10))
        // 5 km in one second: a GPS jump.
        XCTAssertFalse(stats.add(fix: fix(seconds: 2, metersNorth: 5010)))
        XCTAssertEqual(stats.distanceMeters, 10, accuracy: 0.5)
        // Poor accuracy fix is skipped entirely.
        XCTAssertFalse(stats.add(fix: fix(seconds: 3, metersNorth: 20, accuracy: 120)))
        XCTAssertEqual(stats.acceptedFixCount, 2)
        XCTAssertEqual(stats.fixCount, 4)
        // The next plausible fix continues from the last accepted one.
        XCTAssertTrue(stats.add(fix: fix(seconds: 4, metersNorth: 40)))
        XCTAssertEqual(stats.distanceMeters, 40, accuracy: 0.5)
        XCTAssertEqual(stats.movingSeconds, 4, accuracy: 1e-9)
        // A fix with a reported speed over 25 m/s is also dropped.
        XCTAssertFalse(stats.add(fix: fix(seconds: 5, metersNorth: 50, speed: 40)))
    }

    func testElevationGainHysteresis() {
        var stats = RideStatistics()
        let altitudes: [Double] = [100, 101, 99, 100.5, 104, 106, 108, 109, 111, 110, 108, 104, 105, 107]
        for (i, altitude) in altitudes.enumerated() {
            stats.add(fix: fix(seconds: Double(i) * 5, metersNorth: Double(i) * 20, altitude: altitude))
        }
        // Rises: 100->104 (+4), ->108 (+4, via 106 below threshold then 108), ->111 (+3); noise and the drop to 104 add nothing; 104->107 (+3).
        XCTAssertEqual(stats.elevationGainMeters, 14, accuracy: 1e-9)

        var noisy = RideStatistics()
        for i in 0..<20 {
            noisy.add(fix: fix(seconds: Double(i), metersNorth: Double(i) * 5, altitude: 50 + (i % 2 == 0 ? 1.0 : -1.0)))
        }
        XCTAssertEqual(noisy.elevationGainMeters, 0)
    }

    func testSnapshotRoundTripAndResume() throws {
        var stats = RideStatistics()
        for i in 0..<5 {
            stats.add(fix: fix(seconds: Double(i) * 2, metersNorth: Double(i) * 15, altitude: 10 + Double(i) * 4, heartRate: 140))
        }
        let snapshot = stats.snapshot
        let data = try JSONCoding.encode(snapshot)
        let decoded = try JSONCoding.decode(RideSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)

        var resumed = RideStatistics(resuming: snapshot)
        XCTAssertEqual(resumed.distanceMeters, snapshot.distanceMeters)
        XCTAssertEqual(resumed.elapsedSeconds, snapshot.elapsedSeconds)
        resumed.add(fix: fix(seconds: 100, metersNorth: 60))
        resumed.add(fix: fix(seconds: 102, metersNorth: 70))
        XCTAssertEqual(resumed.distanceMeters, snapshot.distanceMeters + 10, accuracy: 0.5)
        XCTAssertEqual(resumed.averageHeartRateBpm ?? 0, 140, accuracy: 1e-9)
    }
}
