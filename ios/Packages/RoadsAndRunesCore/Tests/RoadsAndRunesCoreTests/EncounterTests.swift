import Foundation
import XCTest
@testable import RoadsAndRunesCore

/// The Swift port of the encounter arithmetic is held to the server's fixtures.
final class EncounterTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable { let name: String; let expected: String?; let track: [[Double]] }
        let centre: [Double]
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rune_tracks", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func northbound(_ speeds: [Double], from start: Coordinate = Coordinate(latitude: 51.4906, longitude: -0.0316)) -> [TimedPoint] {
        var points = [TimedPoint(t: 0, coordinate: start)]
        var lat = start.latitude
        for (i, speed) in speeds.enumerated() {
            lat += speed / 111_195
            points.append(TimedPoint(t: Double(i + 1), coordinate: Coordinate(latitude: lat, longitude: start.longitude)))
        }
        return points
    }

    func testRunesAreReadTheSameWayAsOnTheServer() throws {
        let fixture = try fixture()
        let centre = Coordinate(latitude: fixture.centre[0], longitude: fixture.centre[1])
        for aCase in fixture.cases {
            let track = aCase.track.map { Coordinate(latitude: $0[0], longitude: $0[1]) }
            let match = RuneMatcher.match(track: track, centre: centre)
            XCTAssertEqual(match?.shape.rawValue, aCase.expected, aCase.name)
        }
    }

    func testTheTemplatesHaveTheirCorners() {
        for shape in RuneShape.allCases {
            XCTAssertEqual(RuneMatcher.corners(RuneMatcher.templates[shape]!, closed: shape.closed).count, shape.corners, shape.rawValue)
        }
    }

    func testTheFastestKilometreIsFoundAndTimed() {
        let points = northbound(Array(repeating: 5.0, count: 200) + Array(repeating: 8.0, count: 125) + Array(repeating: 5.0, count: 200))
        let window = try! XCTUnwrap(PaceFinder.bestWindow(points, windowMeters: 1000, speedCap: 25))
        XCTAssertEqual(window.seconds, 125, accuracy: 1.5)
        XCTAssertNil(PaceFinder.bestWindow(points, windowMeters: 1000, speedCap: 25, near: Array(repeating: false, count: points.count)))
        XCTAssertNil(PaceFinder.bestWindow(northbound(Array(repeating: 8.0, count: 150)), windowMeters: 600, speedCap: 4))
    }

    func testAChestIsTakenInPassingAndAMonsterFallsToPace() {
        let monster = SampleData.sampleMonster
        let chestOnTheWay = WorldObject(
            id: UUID(), kind: .chest, latitude: monster.latitude - 0.004, longitude: monster.longitude, name: "Old chest",
            rewardAC: 25, expiresAt: Date().addingTimeInterval(86_400)
        )
        var tracker = EncounterTracker(objects: [monster, chestOnTheWay], activity: .ride)
        var claimed: [WorldObject] = []
        var seen: Set<UUID> = []
        // Northbound at 8 m/s (125 s/km) from 900 m south of the monster, straight through both.
        let start = Coordinate(latitude: monster.latitude - 0.0081, longitude: monster.longitude)
        for point in northbound(Array(repeating: 8.0, count: 230), from: start) {
            let result = tracker.update(position: point.coordinate, timestamp: Date(timeIntervalSince1970: point.t), altitude: 10, elevationGainMeters: 0)
            claimed += result.claimed
            if let status = result.status { seen.insert(status.object.id) }
        }
        XCTAssertEqual(Set(claimed.map(\.id)), [chestOnTheWay.id, monster.id])
        XCTAssertEqual(tracker.pendingEvents.map(\.method), ["PASS", "PACE"])
        XCTAssertEqual(seen, [chestOnTheWay.id, monster.id], "both came into sight on the way")

        // A stroll past it is near, but no strike: the status shows the pace method short of done.
        var slow = EncounterTracker(objects: [monster], activity: .ride)
        var last: EncounterStatus?
        for point in northbound(Array(repeating: 3.0, count: 600), from: start) {
            let result = slow.update(position: point.coordinate, timestamp: Date(timeIntervalSince1970: point.t), altitude: 10, elevationGainMeters: 0)
            XCTAssertTrue(result.claimed.isEmpty)
            last = result.status ?? last
        }
        XCTAssertEqual(last?.method, .pace)
        XCTAssertLessThan(last?.progress ?? 1, 1)
        XCTAssertTrue(slow.pendingEvents.isEmpty)
    }
}
