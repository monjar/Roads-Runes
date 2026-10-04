@testable import RoadsAndRunesCore
import XCTest

/// The phone's fight against the server's verdicts on the same outings
/// (`backend/tests/fixtures/fight_tracks.json`, written by gen_fight_fixtures.py).
final class FightResolverTests: XCTestCase {
    struct Fixture: Decodable {
        struct Case: Decodable {
            struct Foe: Decodable {
                var latitude: Double
                var longitude: Double
                var hold: Double
                var wants: [String]
                var minds: [String]
                var roadForm: String?
            }

            struct Expect: Decodable {
                var outcome: String
                var holdAfter: Double
                var damage: [String: Double]
                var finisher: String?
            }

            var name: String
            var points: [[JSONValue]]
            var foe: Foe
            var activity: String
            var pct: [String: Double]
            var newCellIndices: [Int]
            var runeHit: [JSONValue]?
            var wordIndices: [Int]
            var expect: Expect
        }

        var combat: CombatConstants
        var cases: [Case]
    }

    func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fight_tracks", withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testThePhoneFightsAsTheServerDoes() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.cases.isEmpty)
        for c in fixture.cases {
            let points = c.points.map { row in
                FightResolver.Point(
                    latitude: row[0].doubleValue ?? 0, longitude: row[1].doubleValue ?? 0, altitude: row[2].doubleValue,
                    ok: row[3].boolValue ?? true, roadCell: row[4].stringValue ?? ""
                )
            }
            let foe = FightResolver.Foe(latitude: c.foe.latitude, longitude: c.foe.longitude, holdMax: c.foe.hold,
                                        holdBefore: c.foe.hold, wants: c.foe.wants, minds: c.foe.minds, roadForm: c.foe.roadForm)
            let hit = c.runeHit.map { FightResolver.RuneHit(shape: $0[0].stringValue ?? "", index: $0[1].intValue ?? 0) }
            let report = FightResolver.resolve(points, foe: foe, activity: c.activity, pct: c.pct, cfg: fixture.combat,
                                               newCellIndices: c.newCellIndices, runeHit: hit, wordIndices: c.wordIndices)
            XCTAssertEqual(report.outcome, c.expect.outcome, c.name)
            XCTAssertEqual(report.holdAfter, c.expect.holdAfter, accuracy: 1, c.name)
            XCTAssertEqual(report.finisher, c.expect.finisher, c.name)
            for (kind, amount) in c.expect.damage {
                XCTAssertEqual(report.damage[kind] ?? 0, amount, accuracy: 1, "\(c.name): \(kind)")
            }
        }
    }

    func testNoClockIsRead() {
        // The resolver's points carry no time at all: there is nothing to be fast at.
        let mirror = Mirror(reflecting: FightResolver.Point(latitude: 0, longitude: 0, altitude: nil, roadCell: ""))
        XCTAssertFalse(mirror.children.contains { ($0.label ?? "").lowercased().contains("time") })
    }
}
