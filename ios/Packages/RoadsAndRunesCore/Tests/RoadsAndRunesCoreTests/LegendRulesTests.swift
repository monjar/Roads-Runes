import XCTest
@testable import RoadsAndRunesCore

/// Legends, lairs and treasure maps (0.8.0): the mock's rules, the words, and
/// the signature haptics' patterns.
final class LegendRulesTests: XCTestCase {
    // MARK: The mock

    func testTheLegendMovesOnceAndOnlyOnce() async throws {
        let api = MockAPI()
        let state = try await api.legends()
        let legend = try XCTUnwrap(state.awake)
        XCTAssertNil(state.awake?.journeys, "the list leaves the journeys to the legend's own page")
        let page = try await api.legend(id: legend.id)
        XCTAssertEqual(page.journeys?.count, 3)
        let moved = try await api.moveLegend(id: legend.id)
        XCTAssertTrue(moved.moved)
        XCTAssertNotEqual(moved.coordinate, legend.coordinate)
        do {
            _ = try await api.moveLegend(id: legend.id)
            XCTFail("a second move")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.alreadyMoved)
        }
    }

    func testATreasureMapGivesOneClueAtATime() async throws {
        let api = MockAPI()
        let before = try await api.treasureClues()
        XCTAssertTrue(before.isEmpty)
        let here = ConsumableUseRequest(latitude: 51.49, longitude: -0.04)
        let result = try await api.useConsumable(id: ConsumableId.treasureMap, here)
        XCTAssertNotNil(result.treasureClue)
        XCTAssertNil(result.coordinate, "never a place")
        let open = try await api.treasureClues()
        XCTAssertEqual(open.map(\.clue), [result.clue])
        XCTAssertEqual(result.inventory?.count(of: ConsumableId.treasureMap), 0)
        do {
            _ = try await api.useConsumable(id: ConsumableId.treasureMap, here)
            XCTFail("none left, or one open")
        } catch let error as APIError {
            XCTAssertTrue([APIErrorCode.noneLeft, APIErrorCode.oneAtATime].contains(error.errorCode ?? ""))
        }
    }

    func testTheMocksWorldHasALair() async throws {
        let api = MockAPI()
        let objects = try await api.worldObjects(near: SampleData.origin, radiusMeters: 6000)
        let lair = try XCTUnwrap(objects.first(where: \.isLair))
        XCTAssertEqual(lair.lair?.cells.count, 7)
        XCTAssertNil(lair.reachMeters, "a lair is visited, never opened by hand")
    }

    // MARK: The words

    func testTheLegendPageSaysWhatEachKindDoes() {
        XCTAssertEqual(LegendCopy.effort("GROUND", perUnit: 30), "Exploring: 30 per new tile")
        XCTAssertEqual(LegendCopy.effort("ROAD", perUnit: 0.02), "Distance: 20 per km")
        XCTAssertEqual(LegendCopy.effort("CLIMB", perUnit: 2.5), "Climbing: 25 per 10 m")
        XCTAssertEqual(LegendCopy.effort("RUNE", perUnit: 200), "Rune shape: 200, once a day")
        XCTAssertEqual(LegendCopy.effort("WORD", perUnit: 30), "A note: 30, once a day")
        XCTAssertEqual(LegendCopy.effort("ROAD", perUnit: 0.01, units: .imperial), "Distance: 16 per mi")
    }

    /// The page's numbers are the fold's: wanted doubled, resisted halved, on foot scaled, capstones added.
    func testThePagesNumbersAreTheFolds() {
        let phase = LegendPhase(n: 2, weakTo: ["GROUND", "ROAD"], resists: ["WORD"], healthMax: 500, healthLeft: 360)
        let sheet = CharacterSheet()
        XCTAssertEqual(phase.perUnit("GROUND", sheet: sheet, constants: CombatConstants(), activity: .ride), 30, accuracy: 1e-9)
        XCTAssertEqual(phase.perUnit("WORD", sheet: sheet, constants: CombatConstants(), activity: .ride), 30, accuracy: 1e-9)
        XCTAssertEqual(phase.perUnit("CLIMB", sheet: sheet, constants: CombatConstants(), activity: .ride), 1.25, accuracy: 1e-9)
        XCTAssertEqual(phase.perUnit("GROUND", sheet: sheet, constants: CombatConstants(), activity: .run), 60, accuracy: 1e-9)
        var capstone = CharacterSheet()
        capstone.vsLegendsPct = ["GROUND": 0.25]
        XCTAssertEqual(phase.perUnit("GROUND", sheet: capstone, constants: CombatConstants(), activity: .ride), 37.5, accuracy: 1e-9)
    }

    func testHealsAndSleeps() {
        XCTAssertEqual(LegendCopy.healsAndSleeps(healsPerWeek: 50, sleepsAfterDays: 28),
                       "Heals 50 a week if left alone. Sleeps after 4 weeks. It never takes anything from you.")
        XCTAssertEqual(LegendCopy.healsAndSleeps(healsPerWeek: nil, sleepsAfterDays: 10),
                       "Sleeps after 10 days. It never takes anything from you.")
    }

    func testJourneysEndSaysWhatHappenedToTheLegend() {
        var outcome = SampleData.sampleLegendOutcome
        XCTAssertEqual(LegendCopy.outcome(outcome), "Phase broken! The Fog Dragon is down to its last phase.")
        outcome.line = nil
        XCTAssertEqual(LegendCopy.outcome(outcome), "Phase broken! The Fog Dragon is down to its last phase.")
        outcome.phaseAfter = 2
        XCTAssertEqual(LegendCopy.outcome(outcome), "Phase broken! The Fog Dragon has two phases left.")
        outcome.phaseBroken = false
        outcome.damage = 140
        outcome.phaseHealthLeft = 360
        XCTAssertEqual(LegendCopy.outcome(outcome), "The Fog Dragon took 140 damage. 360 left in this phase.")
        outcome.defeated = true
        XCTAssertEqual(LegendCopy.outcome(outcome), "The Fog Dragon is defeated!")
        XCTAssertEqual(LegendCopy.kinds(["GROUND": 240, "ROAD": 120, "WORD": 0]), "Exploring 240 · distance 120")
        XCTAssertNil(LegendCopy.kinds([:]))
        XCTAssertEqual(LegendCopy.woke("The Fog Dragon"), "A legend has woken: the Fog Dragon")
        XCTAssertEqual(LegendCopy.untilNext(1), "Defeat 1 more creature and a legend wakes.")
    }

    func testTheLairCardSaysTheTaskAndTheCount() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let lair = LairInfo(cells: SampleData.lairCells(round: SampleData.origin), visited: [0, 2, 5], need: 5,
                            endsAt: ISO8601.parse("2026-10-14T12:00:00Z"))
        XCTAssertEqual(LairCopy.task(lair, calendar: calendar, locale: Locale(identifier: "en_US")), "Visit 5 of its 7 tiles by Oct 14.")
        XCTAssertEqual(LairCopy.task(LairInfo(cells: lair.cells, need: 5)), "Visit 5 of its 7 tiles.")
        XCTAssertEqual(LairCopy.progress(visited: lair.visitedCount, need: lair.need), "3 / 5 tiles")
        XCTAssertEqual(LairCopy.outcome(LairOutcome(name: "Southwark Park lair", visited: 4, need: 5)), "Southwark Park lair: 4 / 5 tiles.")
        XCTAssertEqual(LairCopy.outcome(SampleData.sampleLairOutcome), "Southwark Park lair done! You opened its great chest.")
    }

    func testEachHardRuneSaysWhereItIsFound() {
        XCTAssertEqual(HardRunes.howToFind("hagalaz"), "Defeat the Fog Dragon to take it.")
        XCTAssertEqual(HardRunes.howToFind("Thurisaz"), "Defeat the Rune Golem to take it.")
        XCTAssertEqual(HardRunes.howToFind("ingwaz"), "Found in a lair's great chest.")
        XCTAssertNil(HardRunes.howToFind("raido"))
        XCTAssertEqual(Set(HardRunes.ids.compactMap(HardRunes.howToFind)).count, 6)
    }

    func testTreasureLines() {
        XCTAssertEqual(TreasureCopy.outcome(TreasureFound(coins: 120)), "You found the buried treasure! +120 coins")
        XCTAssertEqual(TreasureCopy.outcome(TreasureFound(coins: 120, line: "You dug up 120 coins.")), "You dug up 120 coins.")
    }

    // MARK: Signature haptics

    func testEveryPatternStaysInRangeAndShort() {
        for haptic in SignatureHaptic.allCases {
            let pattern = haptic.pattern
            XCTAssertFalse(pattern.events.isEmpty, haptic.rawValue)
            XCTAssertEqual(pattern.events.map(\.time), pattern.events.map(\.time).sorted(), haptic.rawValue)
            for event in pattern.events {
                XCTAssert((0...1).contains(event.intensity) && (0...1).contains(event.sharpness), haptic.rawValue)
                XCTAssertGreaterThanOrEqual(event.time, 0)
            }
            for point in pattern.intensityCurve { XCTAssert((0...1).contains(point.value), haptic.rawValue) }
            XCTAssertLessThanOrEqual(pattern.duration, 2.0, "\(haptic.rawValue) is a moment, not a song")
        }
    }

    func testAChestIsTwoKnocksAndARattle() {
        let taps = SignatureHaptic.chest.pattern.taps
        XCTAssertTrue(SignatureHaptic.chest.pattern.buzzes.isEmpty)
        let knocks = taps.filter { $0.intensity >= 0.8 }
        XCTAssertEqual(knocks.count, 2)
        XCTAssertTrue(knocks.allSatisfy { $0.sharpness < 0.5 }, "a knock is dull")
        let rattle = taps.filter { $0.intensity < 0.8 }
        XCTAssertGreaterThanOrEqual(rattle.count, 4)
        XCTAssertTrue(rattle.allSatisfy { $0.time > (knocks.last?.time ?? 0) && $0.sharpness > 0.6 }, "the rattle comes after, crisp")
    }

    func testAPhaseBrokenIsASwell() {
        let pattern = SignatureHaptic.phaseBroken.pattern
        XCTAssertTrue(pattern.taps.isEmpty)
        XCTAssertEqual(pattern.buzzes.count, 1)
        let values = pattern.intensityCurve.map(\.value)
        let peak = values.firstIndex(of: values.max() ?? 0) ?? 0
        XCTAssertTrue(peak > 0 && peak < values.count - 1, "it rises and falls")
        XCTAssertLessThan(values.first ?? 1, 0.5)
    }

    func testALegendDefeatedIsASwellThenThreeKnocks() {
        let pattern = SignatureHaptic.legendDefeated.pattern
        let swellEnd = pattern.buzzes.map(\.end).max() ?? 0
        XCTAssertEqual(pattern.buzzes.count, 1)
        XCTAssertEqual(pattern.taps.count, 3)
        XCTAssertTrue(pattern.taps.allSatisfy { $0.time > swellEnd })
    }

    func testAShimmerIsLightCrispAndOnlyForRareFinds() {
        let pattern = SignatureHaptic.rareFind.pattern
        XCTAssertGreaterThanOrEqual(pattern.taps.count, 6)
        XCTAssertTrue(pattern.taps.allSatisfy { $0.intensity <= 0.7 && $0.sharpness >= 0.8 })
        XCTAssertEqual(SignatureHaptic.forFind(rarity: "RARE"), .rareFind)
        XCTAssertEqual(SignatureHaptic.forFind(rarity: "legendary"), .rareFind)
        XCTAssertNil(SignatureHaptic.forFind(rarity: "COMMON"))
        XCTAssertNil(SignatureHaptic.forFind(rarity: nil))
        XCTAssertEqual(SignatureHaptic.forLegend(SampleData.sampleLegendOutcome), .phaseBroken)
        var down = SampleData.sampleLegendOutcome
        down.defeated = true
        XCTAssertEqual(SignatureHaptic.forLegend(down), .legendDefeated)
        down.defeated = false
        down.phaseBroken = false
        XCTAssertNil(SignatureHaptic.forLegend(down))
    }
}
