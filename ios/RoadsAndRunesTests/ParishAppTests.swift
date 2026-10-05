import RoadsAndRunesArt
import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// 0.9.0 in the app: districts in the Journal and as quiet labels on the World map,
/// the district line on Next up, the Atlas and its calendar, the look worn, and
/// Tiwaz's opening blow carried into a journey's fight setup.
@MainActor
final class ParishAppTests: XCTestCase {
    private func ready(_ api: MockAPI = MockAPI()) async -> AppContainer {
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        return container
    }

    func testTheDistrictsLoadAndBecomeQuietLabels() async {
        let container = await ready()
        await container.districts.refresh()
        XCTAssertTrue(container.districts.available)
        XCTAssertEqual(container.districts.districts.count, SampleData.sampleDistricts.count)
        XCTAssertEqual(Set(container.districts.labels.map(\.text)), Set(SampleData.sampleDistricts.map(\.name)),
                       "only the districts passed through are named")
        let page = try? await container.districts.page(id: SampleData.bermondseyId)
        XCTAssertNotNil(page?.ledger)
        XCTAssertEqual(DistrictPage.place(for: SampleData.sampleDistricts[0]).name, "Rotherhithe")
    }

    /// Next up names the district here only near a milestone, and asks at most once a minute and 300 m.
    func testNextUpNamesTheDistrictHereNearAMilestone() async {
        let container = await ready()
        let bermondsey = SampleData.sampleDistricts[1]
        let start = Date()
        await container.districts.noticePosition(bermondsey.coordinate, now: start)
        XCTAssertEqual(container.districts.here?.name, "Bermondsey")
        XCTAssertEqual(container.districts.milestoneLine, "Bermondsey is 47% explored. 3% to make it yours.")
        // Rotherhithe is yours at 62%: no milestone near, so nothing to say.
        let rotherhithe = SampleData.sampleDistricts[0]
        await container.districts.noticePosition(rotherhithe.coordinate, now: start.addingTimeInterval(10))
        XCTAssertEqual(container.districts.here?.name, "Bermondsey", "not within a minute")
        await container.districts.noticePosition(rotherhithe.coordinate, now: start.addingTimeInterval(120))
        XCTAssertEqual(container.districts.here?.name, "Rotherhithe")
        XCTAssertNil(container.districts.milestoneLine)
    }

    func testTheJournalHasTheAtlasAndTheDistricts() {
        XCTAssertEqual(JournalSection.map.title(codex: true), "Atlas")
        XCTAssertEqual(JournalSection.districts.title(codex: true), "Districts")
        XCTAssertEqual(JournalSection.allCases.count, 5)
        XCTAssertEqual(JournalSection.districts.identifier, "journal.segment.districts")
    }

    func testTheAtlasLoadsItsYearAndWalksTheCalendar() async throws {
        let api = MockAPI()
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 1
        parts.day = 15
        let today = try XCTUnwrap(Calendar.current.date(from: parts))
        let model = AtlasModel(api: api, today: today)
        await model.load()
        XCTAssertEqual(model.year, 2026)
        XCTAssertEqual(model.paths.count, 3)
        XCTAssertEqual(model.fit.count, 2)
        XCTAssertEqual(model.atlas?.daysByKey["2026-10-03"]?.journeys, 2)
        // Back a month into last year shows last year.
        await model.showMonth(model.month.previous)
        XCTAssertEqual(model.year, 2025)
        XCTAssertEqual(model.month, AtlasCalendar.Month(year: 2025, month: 12))
        XCTAssertTrue(model.atlas?.traces.isEmpty ?? false)
        // Never past this year.
        await model.show(year: 2027)
        XCTAssertEqual(model.year, 2025)
    }

    func testADayKeyIsTheLocalDay() throws {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 3
        parts.hour = 23
        let date = try XCTUnwrap(Calendar.current.date(from: parts))
        XCTAssertEqual(AtlasSection.dayKey(date), "2026-10-03")
        XCTAssertEqual(AtlasSection.shortDay("bad"), "bad")
    }

    func testTheLookWornColoursTheRouteAndFramesTheMarker() async throws {
        let api = MockAPI()
        let container = await ready(api)
        await container.session.refreshInventory()
        XCTAssertEqual(LookStyle.inkHex(container.session.inventory), 0x2E2A24, "everyone has Ink, and wears it first")
        XCTAssertEqual(LookStyle.inkHex(nil), 0xC67139, "with no look at all the route stays terracotta")
        container.session.take(inventory: try await api.setLook(LookChoice(.ink, "ink:sage")))
        XCTAssertEqual(LookStyle.inkHex(container.session.inventory), 0x7A8A5E, "the owned ink's own colour")
        container.session.take(inventory: try await api.setLook(LookChoice(.markerFrame, "marker:rope")))
        XCTAssertEqual(LookStyle.MarkerFrame(container.session.inventory?.look?.markerFrame), .rope)
        XCTAssertEqual(LookStyle.MarkerFrame("marker:unknown"), .plain, "a frame the app does not know draws plain")
        XCTAssertEqual(LookStyle.MarkerFrame(nil), .plain)
    }

    func testCrestFramesComeFromDeedsAndTheStall() {
        let deed = LookStyle.CrestFrame("crest:legs-3")
        XCTAssertEqual(deed?.ticks, 3)
        XCTAssertEqual(deed?.double, false)
        XCTAssertEqual(LookStyle.CrestFrame("crest:ink-5")?.double, true)
        XCTAssertEqual(LookStyle.CrestFrame("crest:oak")?.ticks, 12)
        XCTAssertEqual(LookStyle.CrestFrame("crest:silver")?.double, true)
        XCTAssertEqual(LookStyle.CrestFrame("crest:starry")?.ticks, 8)
        XCTAssertNotNil(LookStyle.CrestFrame("crest:something-new"), "a frame the app does not know still draws")
        XCTAssertNil(LookStyle.CrestFrame(nil))
        XCTAssertNil(LookStyle.CrestFrame("crest:plain"))
    }

    func testJourneysEndNamesItsDistrictsAndThePay() async throws {
        let api = MockAPI()
        api.summaryPollsBeforeReady = 0
        let maybe = try await api.rideSummary(id: SampleData.rideId)
        let summary = try XCTUnwrap(maybe)
        XCTAssertEqual(summary.districtsMadeYours, ["Bermondsey"])
        XCTAssertEqual(DistrictCopy.pay(try XCTUnwrap(summary.districtPay)), "Your districts paid 5 coins this week: Rotherhithe.")
    }

    /// Tiwaz: the fight setup carries the quarry, and keeps it through a crash.
    func testTheFightSetupKeepsTheQuarry() {
        let quarry = UUID()
        let setup = FightTracker.Setup(constants: CombatConstants(), sheet: .neutral, activity: .ride, knownCells: [],
                                       groundResolution: 9, indexing: H3CellIndexing(), quarryId: quarry)
        let saved = FightSetupState(setup)
        XCTAssertEqual(saved.quarryId, quarry)
        XCTAssertEqual(saved.setup(activity: .ride, indexing: H3CellIndexing()).quarryId, quarry)
    }
}
