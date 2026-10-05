import XCTest
@testable import RoadsAndRunesCore

/// The Hard Six in the phone's fold (0.8.0), as `characters/sheet.py` and
/// `world_objects/fight.py` have them: Nauthiz (ENGAGE_M), Uruz (CLIMB_SHARED_M),
/// Thurisaz (ELDER_CARRIED_SCALE), and the capstones against a legend.
final class HardSixFightTests: XCTestCase {
    private let home = Coordinate(latitude: 51.4906, longitude: -0.0316)

    /// West to east, a point every 20 m, `offset` metres north of the thing, each in
    /// its own road cell; height from `climb(metresFromStart)`.
    private func track(from west: Double = 800, length: Double = 1600, offset: Double = 0,
                       climb: (Double) -> Double = { _ in 10 }) -> [FightResolver.Point] {
        let start = GeoMath.destination(from: GeoMath.destination(from: home, bearingDegrees: 0, distanceMeters: offset),
                                        bearingDegrees: 270, distanceMeters: west)
        return (0...Int(length / 20)).map { k in
            let along = Double(k) * 20
            let p = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: along)
            return FightResolver.Point(latitude: p.latitude, longitude: p.longitude, altitude: climb(along), roadCell: "c\(k)")
        }
    }

    private func foe(hold: Double = 4000, wants: [String] = ["CLIMB", "WORD"]) -> FightResolver.Foe {
        FightResolver.Foe(latitude: home.latitude, longitude: home.longitude, holdMax: hold, holdBefore: hold, wants: wants, minds: [])
    }

    func testNauthizWidensWhatCountsAsMet() {
        let passing = track(offset: 200)
        let plain = FightResolver.resolve(passing, foe: foe(), activity: "RIDE", pct: [:], cfg: CombatConstants())
        XCTAssertEqual(plain.outcome, "NOT_NEAR", "200 m off is not met")
        let cfg = CombatConstants().with(rules: ["ENGAGE_M": 250])
        XCTAssertEqual(cfg.engageMeters, 250)
        XCTAssertNotEqual(FightResolver.resolve(passing, foe: foe(), activity: "RIDE", pct: [:], cfg: cfg).outcome, "NOT_NEAR")
        XCTAssertEqual(CombatConstants().with(rules: ["ENGAGE_M": 100]).engageMeters, 150, "it only ever widens")
    }

    /// Uruz: height climbed near it before contact counts in full, as climbing
    /// blows at contact, instead of a fraction of it in the opening blow.
    func testUruzCountsClimbingNearItInFull() {
        // 30 m climbed over the first 300 m, from 800 m to 500 m west of it.
        let hilly = track(climb: { along in min(along, 300) / 10 })
        let plain = FightResolver.resolve(hilly, foe: foe(), activity: "RIDE", pct: [:], cfg: CombatConstants())
        XCTAssertNil(plain.units["CLIMB"], "climbing before contact is only carried")
        XCTAssertGreaterThan(plain.damage["CARRIED"] ?? 0, 0)

        let cfg = CombatConstants().with(rules: ["CLIMB_SHARED_M": 1000])
        XCTAssertEqual(cfg.climbSharedMeters, 1000)
        let shared = FightResolver.resolve(hilly, foe: foe(), activity: "RIDE", pct: [:], cfg: cfg)
        XCTAssertEqual(shared.units["CLIMB"] ?? 0, 30, accuracy: 0.001, "every band within reach counts")
        XCTAssertEqual(shared.damage["CLIMB"] ?? 0, 30 * 1.25 * 2, accuracy: 0.001, "at the full rate, and wanted")
        XCTAssertGreaterThan(shared.taken, plain.taken)

        // Only what was climbed within its reach: from 800 to 500 m out, a 600 m reach takes the last 100 m of it.
        let near = FightResolver.resolve(hilly, foe: foe(), activity: "RIDE", pct: [:], cfg: CombatConstants().with(rules: ["CLIMB_SHARED_M": 600]))
        let units = near.units["CLIMB"] ?? 0
        XCTAssertGreaterThan(units, 0)
        XCTAssertLessThan(units, 30)
    }

    /// Thurisaz: the opening blow is stronger against an elder, a bounty or a legend, and only those.
    func testThurisazStrengthensTheOpeningBlowOnElders() {
        var sheet = CharacterSheet()
        sheet.rules = ["ELDER_CARRIED_SCALE": 2]
        let cfg = CombatConstants()
        XCTAssertEqual(sheet.foeConstants(cfg, elder: true).carriedFraction, cfg.carriedFraction * 2, accuracy: 1e-12)
        XCTAssertEqual(sheet.foeConstants(cfg, elder: false).carriedFraction, cfg.carriedFraction)
        XCTAssertEqual(sheet.foeConstants(cfg, elder: true).carriedCap, cfg.carriedCap, "the cap is not scaled")
        XCTAssertEqual(CharacterSheet().foeConstants(cfg, elder: true), cfg)

        let points = track(from: 2000, length: 2400, climb: { along in min(along, 600) / 10 })
        let elder = FightResolver.resolve(points, foe: foe(wants: ["WORD"]), activity: "RIDE", pct: [:], cfg: sheet.foeConstants(cfg, elder: true))
        let plain = FightResolver.resolve(points, foe: foe(wants: ["WORD"]), activity: "RIDE", pct: [:], cfg: cfg)
        XCTAssertEqual(elder.damage["CARRIED"] ?? 0, 2 * (plain.damage["CARRIED"] ?? 0), accuracy: 1e-6)
    }

    /// Against a legend: an elder's build and Thurisaz, plus the capstones and the Loremaster's reach.
    func testALegendTakesTheCapstones() {
        var sheet = CharacterSheet()
        sheet.vsEldersPct = 0.1
        sheet.vsLegendsPct = ["GROUND": 0.25]
        sheet.legendWordRadiusMeters = 500
        sheet.rules = ["ELDER_CARRIED_SCALE": 1.5]
        let pct = sheet.pctAgainstLegend(madeGoodMeters: 0, onFoot: false)
        XCTAssertEqual(pct["GROUND"] ?? 0, 0.35, accuracy: 1e-9)
        XCTAssertEqual(pct["ROAD"] ?? 0, 0.1, accuracy: 1e-9)
        let cfg = sheet.legendConstants(CombatConstants())
        XCTAssertEqual(cfg.wordRadiusMeters, 500)
        XCTAssertEqual(cfg.carriedFraction, CombatConstants().carriedFraction * 1.5, accuracy: 1e-12)

        let legend = SampleData.sampleLegend.foe!
        let creature = SampleData.sampleMonster
        XCTAssertEqual(FightTracker.against(legend, sheet: sheet, cfg: CombatConstants(), madeGoodMeters: 0, onFoot: false).cfg.wordRadiusMeters, 500)
        XCTAssertEqual(FightTracker.against(creature, sheet: sheet, cfg: CombatConstants(), madeGoodMeters: 0, onFoot: false).cfg.wordRadiusMeters, 120)
    }

    /// One phase a day: with a phase broken today, the next holds at 1 however hard it is hit.
    func testALegendBreaksOnePhaseADay() throws {
        func ride(heldToday: Bool) throws -> (claimed: Bool, left: Double?) {
            var legend = SampleData.sampleLegend
            legend.latitude = home.latitude
            legend.longitude = home.longitude
            legend.phases[1] = LegendPhase(n: 2, weakTo: ["ROAD"], resists: [], healthMax: 500, healthLeft: 5)
            legend.phaseBrokenToday = heldToday
            let foe = try XCTUnwrap(legend.foe)
            let elsewhere = BoundingBox(minLat: 10, minLon: 10, maxLat: 10.1, maxLon: 10.1)
            let setup = FightTracker.Setup(constants: CombatConstants(), sheet: CharacterSheet(), activity: .ride, knownCells: [],
                                           groundResolution: 9, indexing: FakeCellIndexing(), readBounds: elsewhere)
            var tracker = EncounterTracker(objects: [foe], activity: .ride, fights: setup)
            let start = GeoMath.destination(from: home, bearingDegrees: 270, distanceMeters: 900)
            for k in 0...260 {
                let p = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: Double(k) * 10)
                _ = tracker.update(position: p, timestamp: Date(timeIntervalSince1970: Double(k) * 2), altitude: 10, elevationGainMeters: 0,
                                   accuracy: 5)
            }
            return (tracker.claimedIDs.contains(foe.id), tracker.fights?.holdFraction(of: foe.id))
        }
        XCTAssertTrue(try ride(heldToday: false).claimed, "5 left falls to the road it is weak to")
        let held = try ride(heldToday: true)
        XCTAssertFalse(held.claimed, "not twice in a day")
        XCTAssertEqual(held.left ?? 0, 1.0 / 500, accuracy: 1e-9)
    }

    /// The legend on a journey: fought as its phase, and the capstones make it hurt more.
    func testTheRideFightsTheLegendsPhase() throws {
        var legend = SampleData.sampleLegend
        legend.latitude = home.latitude
        legend.longitude = home.longitude
        let foe = try XCTUnwrap(legend.foe)
        func ride(_ sheet: CharacterSheet) -> Double? {
            // Ground read only far away: no new tiles count, only the distance.
            let elsewhere = BoundingBox(minLat: 10, minLon: 10, maxLat: 10.1, maxLon: 10.1)
            let setup = FightTracker.Setup(constants: CombatConstants(), sheet: sheet, activity: .ride, knownCells: [],
                                           groundResolution: 9, indexing: FakeCellIndexing(), readBounds: elsewhere)
            var tracker = EncounterTracker(objects: [foe], activity: .ride, fights: setup)
            let start = GeoMath.destination(from: home, bearingDegrees: 270, distanceMeters: 900)
            for k in 0...260 {
                let p = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: Double(k) * 10)
                _ = tracker.update(position: p, timestamp: Date(timeIntervalSince1970: Double(k) * 2), altitude: 10, elevationGainMeters: 0,
                                   accuracy: 5)
            }
            return tracker.fights?.holdFraction(of: foe.id)
        }
        let plain = try XCTUnwrap(ride(CharacterSheet()))
        XCTAssertLessThan(plain, 360.0 / 500.0, "distance hurts this phase")
        XCTAssertGreaterThan(plain, 0, "and does not break it")
        var capstone = CharacterSheet()
        capstone.vsLegendsPct = ["ROAD": 0.25]
        let stronger = try XCTUnwrap(ride(capstone))
        XCTAssertLessThan(stronger, plain)
    }
}
