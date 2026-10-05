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
                /// What is left before the outing, when less than `hold` (0.8.0).
                var holdBefore: Double?
                var wants: [String]
                var minds: [String]
                var roadForm: String?
            }

            /// A legend's phase (0.8.0): the foe is this phase.
            struct LegendCase: Decodable {
                var speciesId: String
                var phase: Int
                var weakTo: [String]
                var resists: [String]
                var rune: String?
                var healthMax: Int
                var healthLeft: Int
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
            /// The sheet's rules for this case (0.7.2: `FINISH_UNDER`, `GROUND_CELL_SCALE`); absent before.
            var rules: [String: Double]?
            /// Health before the outing, when it was already weakened; `hold` otherwise.
            var holdBefore: Double?
            /// 0.8.0: an elder, a bounty or a legend (Thurisaz); a legend's phase and the capstones against it.
            var elder: Bool?
            /// 0.9.0: the creature the journey was planned for (Tiwaz, `QUARRY_CARRIED_SCALE`).
            var quarry: Bool?
            var legend: LegendCase?
            var vsLegendsPct: [String: Double]?
            var legendWordRadiusMeters: Double?
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
            var foe = FightResolver.Foe(latitude: c.foe.latitude, longitude: c.foe.longitude, holdMax: c.foe.hold,
                                        holdBefore: c.foe.holdBefore ?? c.holdBefore ?? c.foe.hold, wants: c.foe.wants, minds: c.foe.minds,
                                        roadForm: c.foe.roadForm)
            // The build as the phone's sheet folds it: the rules, then against this one (0.8.0).
            var sheet = CharacterSheet(damagePct: c.pct)
            sheet.rules = c.rules
            sheet.vsLegendsPct = c.vsLegendsPct
            sheet.legendWordRadiusMeters = c.legendWordRadiusMeters
            let cfg = sheet.fightConstants(fixture.combat)
            var pct = c.pct
            var against = sheet.foeConstants(cfg, elder: c.elder ?? false, quarry: c.quarry ?? false)
            if let spec = c.legend {
                // The legend's phase as the ride fights it (`Legend.foe`), and the build against a legend.
                let phase = LegendPhase(n: spec.phase, weakTo: spec.weakTo, resists: spec.resists, healthMax: spec.healthMax,
                                        healthLeft: spec.healthLeft, rune: spec.rune, roadForm: c.foe.roadForm)
                let legend = Legend(id: UUID(), speciesId: spec.speciesId, name: c.name, latitude: c.foe.latitude, longitude: c.foe.longitude,
                                    phase: spec.phase, phases: [phase])
                let object = try XCTUnwrap(legend.foe, c.name)
                let monster = try XCTUnwrap(object.monster, c.name)
                foe = FightResolver.Foe(latitude: object.latitude, longitude: object.longitude, holdMax: Double(monster.holdMax ?? 0),
                                        holdBefore: Double(monster.holdLeft ?? 0), wants: monster.wants ?? [], minds: monster.minds ?? [],
                                        roadForm: monster.roadForm)
                XCTAssertEqual(foe.wants, c.foe.wants, c.name)
                XCTAssertEqual(foe.minds, c.foe.minds, c.name)
                XCTAssertEqual(foe.holdMax, c.foe.hold, c.name)
                XCTAssertEqual(foe.holdBefore, c.foe.holdBefore ?? c.foe.hold, c.name)
                (pct, against) = FightTracker.against(object, sheet: sheet, cfg: cfg, madeGoodMeters: 0,
                                                      onFoot: ["RUN", "WALK"].contains(c.activity.uppercased()), quarry: c.quarry ?? false)
            }
            let hit = c.runeHit.map { FightResolver.RuneHit(shape: $0[0].stringValue ?? "", index: $0[1].intValue ?? 0) }
            let report = FightResolver.resolve(points, foe: foe, activity: c.activity, pct: pct, cfg: against,
                                               newCellIndices: c.newCellIndices, runeHit: hit, wordIndices: c.wordIndices)
            XCTAssertEqual(report.outcome, c.expect.outcome, c.name)
            XCTAssertEqual(report.holdAfter, c.expect.holdAfter, accuracy: 1, c.name)
            XCTAssertEqual(report.finisher, c.expect.finisher, c.name)
            for (kind, amount) in c.expect.damage {
                XCTAssertEqual(report.damage[kind] ?? 0, amount, accuracy: 1, "\(c.name): \(kind)")
            }
        }
    }

    // MARK: Gear in the fight (0.7.2)

    private let home = Coordinate(latitude: 51.4906, longitude: -0.0316)

    /// West to east through the creature, a point every 20 m, each in its own road cell.
    private func track(from west: Double = 600, length: Double = 1400) -> [FightResolver.Point] {
        let start = GeoMath.destination(from: home, bearingDegrees: 270, distanceMeters: west)
        return (0...Int(length / 20)).map { k in
            let p = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: Double(k) * 20)
            return FightResolver.Point(latitude: p.latitude, longitude: p.longitude, altitude: 10, roadCell: "c\(k)")
        }
    }

    private func foe(hold: Double = 220, before: Double? = nil, wants: [String] = ["GROUND", "WORD"]) -> FightResolver.Foe {
        FightResolver.Foe(latitude: home.latitude, longitude: home.longitude, holdMax: hold, holdBefore: before ?? hold, wants: wants,
                          minds: ["CLIMB"])
    }

    /// The Unrung Bell: a creature left with no more than a tenth of its health is
    /// defeated, and one left with more is not.
    func testTheUnrungBellFinishesWhatIsNearlyDone() {
        let points = track()
        let cfg = CombatConstants()
        let plain = FightResolver.resolve(points, foe: foe(), activity: "RIDE", pct: [:], cfg: cfg)
        XCTAssertEqual(plain.outcome, "LOOSENED")
        let share = plain.holdAfter / 220

        let finished = FightResolver.resolve(points, foe: foe(), activity: "RIDE", pct: [:], cfg: cfg.with(rules: ["FINISH_UNDER": share + 0.001]))
        XCTAssertEqual(finished.outcome, "SEEN_OFF")
        XCTAssertEqual(finished.holdAfter, 0)
        XCTAssertEqual(finished.finisher, "ROAD", "the last blow that landed")
        XCTAssertEqual(finished.damage["CARRIED"], plain.damage["CARRIED"], "the blows before the last are unchanged")
        XCTAssertEqual(finished.damage.values.reduce(0, +), 220, accuracy: 0.001,
                       "what was left goes on the last blow that landed, as on the server")

        let short = FightResolver.resolve(points, foe: foe(), activity: "RIDE", pct: [:], cfg: cfg.with(rules: ["FINISH_UNDER": share - 0.01]))
        XCTAssertEqual(short.outcome, "LOOSENED")
        XCTAssertEqual(short.holdAfter, plain.holdAfter)

        // Already weakened under the line before the outing: meeting it is enough.
        let met = FightResolver.resolve(points, foe: foe(before: 15), activity: "RIDE", pct: [:],
                                        cfg: CombatConstants().with(rules: ["FINISH_UNDER": 0.1, "CARRIED_SCALE": 0.0001]))
        XCTAssertEqual(met.outcome, "SEEN_OFF")
        // Never reached: nothing to finish.
        let away = FightResolver.resolve(track(from: 6000, length: 200), foe: foe(before: 15), activity: "RIDE", pct: [:],
                                         cfg: cfg.with(rules: ["FINISH_UNDER": 0.1]))
        XCTAssertEqual(away.outcome, "NOT_NEAR")
    }

    func testTheFinishLineIsInclusiveAndOffAtZero() {
        XCTAssertTrue(FightResolver.finished(holdLeft: 22, holdMax: 220, under: 0.1))
        XCTAssertFalse(FightResolver.finished(holdLeft: 23, holdMax: 220, under: 0.1))
        XCTAssertFalse(FightResolver.finished(holdLeft: 0, holdMax: 220, under: 0.1))
        XCTAssertFalse(FightResolver.finished(holdLeft: 1, holdMax: 220, under: 0))
    }

    /// The Cartographer's Atlas: each new tile is 1.25 of exploring, before contact and after.
    func testTheAtlasMakesEachNewTileCountMore() {
        let points = track()
        let after = [40, 45, 50, 55]
        let cfg = CombatConstants()
        let plain = FightResolver.resolve(points, foe: foe(hold: 4000), activity: "RIDE", pct: [:], cfg: cfg, newCellIndices: after)
        let atlas = FightResolver.resolve(points, foe: foe(hold: 4000), activity: "RIDE", pct: [:], cfg: cfg.with(rules: ["GROUND_CELL_SCALE": 1.25]),
                                          newCellIndices: after)
        XCTAssertEqual(plain.units["GROUND"], 4)
        XCTAssertEqual(atlas.units["GROUND"], 5)
        XCTAssertEqual(atlas.damage["GROUND"] ?? 0, (plain.damage["GROUND"] ?? 0) * 1.25, accuracy: 1e-9)

        // New tiles before contact are carried in, scaled the same.
        let before = [2, 4, 6]
        let carriedPlain = FightResolver.resolve(points, foe: foe(hold: 4000), activity: "RIDE", pct: [:], cfg: cfg, newCellIndices: before)
        let carriedAtlas = FightResolver.resolve(points, foe: foe(hold: 4000), activity: "RIDE", pct: [:],
                                                 cfg: cfg.with(rules: ["GROUND_CELL_SCALE": 1.25]), newCellIndices: before)
        XCTAssertGreaterThan(carriedAtlas.damage["CARRIED"] ?? 0, carriedPlain.damage["CARRIED"] ?? 0)
    }

    func testNoClockIsRead() {
        // The resolver's points carry no time at all: there is nothing to be fast at.
        let mirror = Mirror(reflecting: FightResolver.Point(latitude: 0, longitude: 0, altitude: nil, roadCell: ""))
        XCTAssertFalse(mirror.children.contains { ($0.label ?? "").lowercased().contains("time") })
    }
}
