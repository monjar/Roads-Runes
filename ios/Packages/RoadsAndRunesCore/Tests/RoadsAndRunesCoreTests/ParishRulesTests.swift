import XCTest
@testable import RoadsAndRunesCore

/// The parish (0.9.0): the words for districts and festivals, the calendar's
/// month grid, the mock's districts, Atlas and looks, and Tiwaz's opening blow.
final class ParishRulesTests: XCTestCase {
    private func district(_ percent: Double?, yours: Bool = false, wasYours: Bool = false, completed: Bool = false) -> District {
        District(id: "d", name: "Rotherhithe", title: "the Riverlands", percent: percent, exploredTiles: 12, yours: yours, wasYours: wasYours,
                 completed: completed, weeklyCoins: 5, latitude: 51.5, longitude: -0.05)
    }

    func testTheTitleComesAfterACommaAndTheFogBelowTenPercent() {
        XCTAssertEqual(DistrictCopy.fullName(name: "Rotherhithe", title: "the Riverlands", percent: 47), "Rotherhithe, the Riverlands")
        XCTAssertEqual(DistrictCopy.fullName(name: "Rotherhithe", title: "the Riverlands", percent: 9.9), "Rotherhithe, in the fog")
        XCTAssertEqual(DistrictCopy.fullName(name: "Rotherhithe", title: nil, percent: nil), "Rotherhithe, in the fog")
        XCTAssertEqual(DistrictCopy.progress(percent: nil, tiles: 1), "1 tile explored")
        XCTAssertEqual(DistrictCopy.progress(percent: 99.9, tiles: 1), "99% explored")
    }

    func testYoursAndWasYours() {
        XCTAssertEqual(DistrictCopy.standing(district(62, yours: true)), "Rotherhithe is yours. 5 coins a week while you keep visiting.")
        XCTAssertEqual(DistrictCopy.standing(district(55, wasYours: true)), "Rotherhithe was yours. Visit again to make it yours.")
        XCTAssertEqual(DistrictCopy.standing(district(47)), "3% more to make it yours.")
        XCTAssertNil(DistrictCopy.standing(district(nil)))
        XCTAssertEqual(DistrictCopy.standing(district(92, yours: true, completed: true)),
                       "District complete! Rotherhithe is yours. 5 coins a week while you keep visiting.")
    }

    /// Next up names the district only near a milestone, and never as a percentage before the roads are known.
    func testNextUpNamesADistrictNearAMilestone() {
        XCTAssertEqual(DistrictCopy.nearMilestone(district(47)), "Rotherhithe is 47% explored. 3% to make it yours.")
        XCTAssertEqual(DistrictCopy.nearMilestone(district(86, yours: true)), "Rotherhithe is 86% explored. 4% to complete it.")
        XCTAssertNil(DistrictCopy.nearMilestone(district(20)))
        XCTAssertNil(DistrictCopy.nearMilestone(district(62, yours: true)))
        XCTAssertNil(DistrictCopy.nearMilestone(district(nil)))
        XCTAssertNil(DistrictCopy.nearMilestone(district(95, yours: true, completed: true)))
        XCTAssertEqual(DistrictCopy.nearMilestone(district(55, wasYours: true)), "Rotherhithe was yours. Visit again to make it yours.")
    }

    func testTheFourFestivals() {
        XCTAssertEqual(SeasonCopy.name("SPRING_FESTIVAL"), "Spring Festival")
        XCTAssertEqual(SeasonCopy.name("midsummer"), "Midsummer")
        XCTAssertEqual(SeasonCopy.name("Harvest"), "Harvest")
        XCTAssertEqual(SeasonCopy.name("MIDWINTER"), "Midwinter")
        XCTAssertNil(SeasonCopy.name(nil))
        XCTAssertEqual(SeasonCopy.icon("MIDWINTER"), "midwinter")
        // Midsummer's window closes at midnight UTC after 7 July: its last day is the 7th.
        let ends = SeasonCopy.ends(Date(timeIntervalSince1970: 1_783_468_800), locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(ends, "Ends 7 Jul")
        for season in ["SPRING_FESTIVAL", "MIDSUMMER", "HARVEST", "MIDWINTER"] {
            XCTAssertNotEqual(SeasonCopy.icon(season), "sparkles")
        }
    }

    func testTheCalendarGridStartsOnMonday() {
        // October 2026 begins on a Thursday and has 31 days.
        let october = AtlasCalendar.Month(year: 2026, month: 10)
        let grid = AtlasCalendar.grid(october)
        XCTAssertEqual(grid.first, [nil, nil, nil, 1, 2, 3, 4])
        XCTAssertEqual(grid.flatMap { $0 }.compactMap { $0 }.count, 31)
        XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
        XCTAssertEqual(AtlasCalendar.daysIn(AtlasCalendar.Month(year: 2028, month: 2)), 29)
        XCTAssertEqual(AtlasCalendar.key(october, day: 3), "2026-10-03")
        XCTAssertEqual(AtlasCalendar.month(of: "2026-09-28T08:00:00Z"), AtlasCalendar.Month(year: 2026, month: 9))
        XCTAssertEqual(october.next, AtlasCalendar.Month(year: 2026, month: 11))
        XCTAssertEqual(AtlasCalendar.Month(year: 2026, month: 1).previous, AtlasCalendar.Month(year: 2025, month: 12))
    }

    func testTheMockHasDistrictsAnAtlasAndAFestival() async throws {
        let api = MockAPI()
        let districts = try await api.districts()
        XCTAssertEqual(districts.first?.name, "Rotherhithe", "last passed first")
        XCTAssertTrue(districts.allSatisfy { $0.ledger == nil })
        let page = try await api.district(id: SampleData.bermondseyId)
        XCTAssertNotNil(page.ledger)
        let here = try await api.districtHere(at: SampleData.sampleDistricts[0].coordinate)
        XCTAssertEqual(here?.name, "Rotherhithe")
        let nowhere = try await api.districtHere(at: Coordinate(latitude: 0, longitude: 0))
        XCTAssertNil(nowhere)
        let atlas = try await api.atlas(year: 2026)
        XCTAssertFalse(atlas.traces.isEmpty)
        let before = try await api.atlas(year: 2019)
        XCTAssertTrue(before.traces.isEmpty)
        let arcs = try await api.storyArcs()
        XCTAssertEqual(arcs.filter(\.isSeason).count, 1)
    }

    func testTheMockWearsOnlyWhatIsOwned() async throws {
        let api = MockAPI()
        let after = try await api.setLook(LookChoice(.ink, "ink:sage"))
        XCTAssertEqual(after.look?.ink, "ink:sage")
        XCTAssertEqual(after.look?.markerFrame, "marker:plain", "what is left out stays")
        do {
            _ = try await api.setLook(LookChoice(.markerFrame, "marker:runic"))
            XCTFail("a frame not owned cannot be worn")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.notOwned)
        }
    }

    func testTheStallsLookIsOwnedOnceBought() async throws {
        let api = MockAPI()
        api.storedCoins = 1000
        let after = try await api.buyOffer(id: SampleData.sampleCosmeticOffer.id)
        XCTAssertTrue(after.cosmetics(.ink).contains { $0.itemId == "ink:wizard-blue" })
        XCTAssertFalse(after.bag.contains { $0.itemId == "ink:wizard-blue" }, "a look never goes in the bag")
    }

    func testJourneysEndInTheMockNamesItsDistricts() async throws {
        let api = MockAPI()
        api.summaryPollsBeforeReady = 0
        let summary = try await api.rideSummary(id: SampleData.rideId)
        XCTAssertEqual(summary?.districtsMadeYours, ["Bermondsey"])
        XCTAssertEqual(summary?.districtPay?.coins, 5)
    }

    /// Tiwaz (QUARRY_CARRIED_SCALE), as `foe_cfg(quarry=)`: the opening blow on the quarry only, its cap untouched,
    /// on top of Thurisaz against an elder, and through a legend's constants too.
    func testTiwazScalesTheOpeningBlowOnTheQuarryOnly() {
        var sheet = CharacterSheet.neutral
        sheet.rules = ["QUARRY_CARRIED_SCALE": 1.5]
        let cfg = CombatConstants()
        XCTAssertEqual(sheet.foeConstants(cfg, elder: false, quarry: true).carriedFraction, cfg.carriedFraction * 1.5, accuracy: 1e-9)
        XCTAssertEqual(sheet.foeConstants(cfg, elder: false, quarry: true).carriedCap, cfg.carriedCap)
        XCTAssertEqual(sheet.foeConstants(cfg, elder: true, quarry: false).carriedFraction, cfg.carriedFraction)
        XCTAssertEqual(CharacterSheet.neutral.foeConstants(cfg, elder: false, quarry: true), cfg)
        sheet.rules?["ELDER_CARRIED_SCALE"] = 2
        XCTAssertEqual(sheet.foeConstants(cfg, elder: true, quarry: true).carriedFraction, cfg.carriedFraction * 3, accuracy: 1e-9)
        XCTAssertEqual(sheet.legendConstants(cfg, quarry: true).carriedFraction, cfg.carriedFraction * 3, accuracy: 1e-9)
    }

    /// The tracker folds the quarry with Tiwaz and anything else without it.
    func testTheTrackerScalesOnlyTheQuarry() {
        var sheet = CharacterSheet.neutral
        sheet.rules = ["QUARRY_CARRIED_SCALE": 2]
        var object = SampleData.sampleMonster
        object.tier = 1
        object.bounty = false
        let quarry = FightTracker.against(object, sheet: sheet, cfg: CombatConstants(), madeGoodMeters: 0, onFoot: false, quarry: true)
        let other = FightTracker.against(object, sheet: sheet, cfg: CombatConstants(), madeGoodMeters: 0, onFoot: false)
        XCTAssertEqual(quarry.cfg.carriedFraction, 2 * other.cfg.carriedFraction, accuracy: 1e-9)
    }
}
