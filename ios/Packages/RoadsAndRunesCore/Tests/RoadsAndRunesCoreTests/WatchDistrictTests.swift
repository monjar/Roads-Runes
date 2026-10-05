import XCTest
@testable import RoadsAndRunesCore

/// Districts on the wrist (0.9.0): the district the rider is in rides with each
/// navigation update and is named once a journey at a standstill, never while
/// moving; Journey's end says which were made yours and which completed. Every
/// new field is optional both ways, so a phone or a Watch a release behind still
/// reads the other.
final class WatchDistrictTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let here = Coordinate(latitude: 51.4980, longitude: -0.0500)

    // MARK: The messages

    func testTheUpdateCarriesTheDistrictAndAnOlderPhonesHasNone() throws {
        let update = WatchNavigationUpdate(state: .active, distanceMeters: 4000, elapsedSeconds: 900, elevationGainMeters: 40,
                                           speedMps: 0.2, timestamp: t0, districtName: "Rotherhithe, the Riverlands")
        let decoded = try WatchMessages.navigationUpdate(from: WatchMessages.navigationUpdate(update))
        XCTAssertEqual(decoded, update)
        XCTAssertEqual(decoded.districtName, "Rotherhithe, the Riverlands")

        // An older phone's update: no district.
        let old = try JSONCoding.decode(WatchNavigationUpdate.self, json: """
        {"state": "ACTIVE", "distanceMeters": 4000, "elapsedSeconds": 900, "elevationGainMeters": 40, "speedMps": 0.2,
         "timestamp": "2026-10-05T09:00:00Z"}
        """)
        XCTAssertNil(old.districtName)

        // An older Watch reads the update and lets the district go.
        struct OldUpdate: Decodable {
            var state: NavigationState
            var distanceMeters: Double
            var speedMps: Double?
            var timestamp: Date
        }
        let older = try JSONCoding.decode(OldUpdate.self, from: JSONCoding.encode(update))
        XCTAssertEqual(older.distanceMeters, 4000)
        XCTAssertEqual(older.speedMps, 0.2)
    }

    func testJourneysEndCarriesTheDistrictsAndAnOlderPhonesHasNone() throws {
        let end = WatchJourneyEnd(coins: 40, xp: 120, districts: ["Rotherhithe", "Bermondsey"], completedDistricts: ["Rotherhithe"])
        let decoded = try WatchMessages.journeyEnd(from: WatchMessages.journeyEnd(end))
        XCTAssertEqual(decoded, end)
        XCTAssertEqual(decoded.districts, ["Rotherhithe", "Bermondsey"])
        XCTAssertEqual(decoded.completedDistricts, ["Rotherhithe"])

        let old = try JSONCoding.decode(WatchJourneyEnd.self, json: """
        {"creaturesDefeated": 1, "chestsOpened": 0, "coins": 40, "xp": 120, "finds": []}
        """)
        XCTAssertNil(old.districts)
        XCTAssertNil(old.completedDistricts)

        // An older Watch (0.8.0) reads the rest.
        struct OldEnd: Decodable {
            var coins: Int
            var xp: Int
            var finds: [WatchFind]
            var legend: WatchEndLine?
        }
        let older = try JSONCoding.decode(OldEnd.self, from: JSONCoding.encode(end))
        XCTAssertEqual(older.coins, 40)
        XCTAssertNil(older.legend)
    }

    func testJourneysEndIsBuiltFromTheSummarysDistricts() throws {
        var summary = SampleData.sampleAdventureSummary
        summary.districts = [
            DistrictOutcome(id: "1", name: "Rotherhithe", title: "the Riverlands", percent: 91, newTiles: 12, becameYours: true, completed: true),
            DistrictOutcome(id: "2", name: "Bermondsey", percent: 52, newTiles: 4, becameYours: true),
            DistrictOutcome(id: "3", name: "Deptford", percent: 8, newTiles: 3),
        ]
        let end = WatchJourneyEnd(summary: summary)
        XCTAssertEqual(end.districts, ["Rotherhithe", "Bermondsey"])
        XCTAssertEqual(end.completedDistricts, ["Rotherhithe"])
        XCTAssertEqual(try WatchMessages.journeyEnd(from: WatchMessages.journeyEnd(end)), end)

        // Passed through, nothing made yours or completed; or an older server: none.
        summary.districts = [DistrictOutcome(id: "3", name: "Deptford", percent: 8, newTiles: 3)]
        XCTAssertNil(WatchJourneyEnd(summary: summary).districts)
        XCTAssertNil(WatchJourneyEnd(summary: summary).completedDistricts)
        XCTAssertNil(WatchJourneyEnd(summary: SampleData.sampleAdventureSummary).districts)
    }

    func testDistrictNamesAreEachOnceAndNoneIsNil() {
        XCTAssertEqual(WatchJourneyEnd.districtNames(["Rotherhithe", " Bermondsey ", "Rotherhithe", ""]), ["Rotherhithe", "Bermondsey"])
        XCTAssertNil(WatchJourneyEnd.districtNames([]))
        XCTAssertNil(WatchJourneyEnd.districtNames(["  "]))
    }

    // MARK: Named at a standstill

    func testStillnessCanBeAskedByTheClockBetweenSpeeds() {
        var still = Stillness()
        XCTAssertFalse(still.isStill(at: t0))
        _ = still.update(speedMps: 0.3, at: t0)
        XCTAssertFalse(still.isStill(at: t0.addingTimeInterval(4)))
        XCTAssertTrue(still.isStill(at: t0.addingTimeInterval(5)), "no newer speed: five seconds slow is still")
        _ = still.update(speedMps: 4, at: t0.addingTimeInterval(6))
        XCTAssertFalse(still.isStill(at: t0.addingTimeInterval(60)))
    }

    func testADistrictIsNamedAtTheNextStandstillNeverWhileMoving() {
        var naming = DistrictNaming()
        naming.update(district: "Rotherhithe, the Riverlands", speedMps: 6, at: t0)
        XCTAssertNil(naming.line(at: t0.addingTimeInterval(30)), "never while moving")
        XCTAssertEqual(naming.waiting, "Rotherhithe, the Riverlands")

        // Slowing to a stop: not yet five seconds.
        naming.update(district: "Rotherhithe, the Riverlands", speedMps: 0.4, at: t0.addingTimeInterval(40))
        XCTAssertNil(naming.line(at: t0.addingTimeInterval(44)))
        // Five seconds still, and the phone has gone quiet: the clock names it.
        XCTAssertEqual(naming.line(at: t0.addingTimeInterval(45)), "Rotherhithe, the Riverlands")
        // It stays while the rider stands.
        naming.update(district: "Rotherhithe, the Riverlands", speedMps: 0, at: t0.addingTimeInterval(50))
        XCTAssertEqual(naming.line(at: t0.addingTimeInterval(50)), "Rotherhithe, the Riverlands")
        XCTAssertEqual(naming.named, ["Rotherhithe, the Riverlands"])
        naming.update(district: "Rotherhithe, the Riverlands", speedMps: 0.1, at: t0.addingTimeInterval(80))
        XCTAssertEqual(naming.line(at: t0.addingTimeInterval(85)), "Rotherhithe, the Riverlands")

        // Moving off: it goes, and the same district is not named again this journey.
        naming.update(district: "Rotherhithe, the Riverlands", speedMps: 5, at: t0.addingTimeInterval(90))
        XCTAssertNil(naming.line(at: t0.addingTimeInterval(90)))
        naming.update(district: "Rotherhithe, the Riverlands", speedMps: 0, at: t0.addingTimeInterval(120))
        XCTAssertNil(naming.line(at: t0.addingTimeInterval(130)), "once a journey")
        XCTAssertNil(naming.waiting)
    }

    func testANamedDistrictLeftWhileStillIsNamedAndTheNextWaitsForItsStandstill() {
        var naming = DistrictNaming()
        // Stopped already when the phone learns the district: named now.
        naming.update(district: nil, speedMps: 0, at: t0)
        naming.update(district: "Bermondsey, in the fog", speedMps: 0, at: t0.addingTimeInterval(6))
        XCTAssertEqual(naming.line(at: t0.addingTimeInterval(6)), "Bermondsey, in the fog")
        // Moving off right after: it was on screen, so it counts as named.
        naming.update(district: "Bermondsey, in the fog", speedMps: 4, at: t0.addingTimeInterval(8))
        XCTAssertEqual(naming.named, ["Bermondsey, in the fog"])
        XCTAssertNil(naming.line(at: t0.addingTimeInterval(20)))

        // Riding through Rotherhithe without stopping, into Deptford: the next
        // standstill names where the rider is, not where they were.
        naming.update(district: "Rotherhithe, the Riverlands", speedMps: 6, at: t0.addingTimeInterval(100))
        naming.update(district: "Deptford, the Old Stones", speedMps: 6, at: t0.addingTimeInterval(200))
        naming.update(district: "Deptford, the Old Stones", speedMps: 0.2, at: t0.addingTimeInterval(210))
        XCTAssertEqual(naming.line(at: t0.addingTimeInterval(216)), "Deptford, the Old Stones")
        // An unknown speed is moving.
        naming.update(district: "Deptford, the Old Stones", speedMps: nil, at: t0.addingTimeInterval(220))
        XCTAssertNil(naming.line(at: t0.addingTimeInterval(230)))
        // No district from the phone: nothing waits.
        naming.update(district: nil, speedMps: 0, at: t0.addingTimeInterval(300))
        XCTAssertNil(naming.line(at: t0.addingTimeInterval(310)))
    }

    // MARK: Asking the server

    func testThePhoneAsksAtMostOnceAMinuteAndOnlyOnceMovedOn() {
        var lookout = DistrictLookout()
        XCTAssertTrue(lookout.shouldAsk(from: here, at: t0), "the first fix asks")
        XCTAssertFalse(lookout.shouldAsk(from: far(400), at: t0.addingTimeInterval(120)), "one question at a time")
        lookout.answered("Rotherhithe, the Riverlands")
        XCTAssertEqual(lookout.name, "Rotherhithe, the Riverlands")

        XCTAssertFalse(lookout.shouldAsk(from: far(400), at: t0.addingTimeInterval(30)), "not within the minute")
        XCTAssertFalse(lookout.shouldAsk(from: far(200), at: t0.addingTimeInterval(90)), "not within 300 m")
        XCTAssertTrue(lookout.shouldAsk(from: far(400), at: t0.addingTimeInterval(90)))
        // No signal: the last answer stands, and the next ask waits its minute and its 300 m.
        lookout.failed()
        XCTAssertEqual(lookout.name, "Rotherhithe, the Riverlands")
        XCTAssertFalse(lookout.shouldAsk(from: far(500), at: t0.addingTimeInterval(100)))
        XCTAssertTrue(lookout.shouldAsk(from: far(800), at: t0.addingTimeInterval(160)))
        // Outside every district.
        lookout.answered(nil)
        XCTAssertNil(lookout.name)
    }

    private func far(_ meters: Double) -> Coordinate {
        GeoMath.destination(from: here, bearingDegrees: 90, distanceMeters: meters)
    }
}
