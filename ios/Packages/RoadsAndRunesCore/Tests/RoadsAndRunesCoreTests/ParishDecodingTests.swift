import XCTest
@testable import RoadsAndRunesCore

/// The parish (0.9.0) as the contract's payloads have it: districts, the Atlas,
/// festival arcs, looks, place lore and Journey's end; and every new field on an
/// older type read from a server that never sent it.
final class ParishDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: Data(json.utf8))
    }

    static let districtJSON = #"""
    {"id": "c0ffee00-0000-4000-8000-00000000e001", "name": "Rotherhithe", "kind": "suburb", "title": "the Riverlands",
     "displayName": "Rotherhithe, the Riverlands", "percent": 47.6, "exploredTiles": 31, "wayTiles": 66, "yours": false,
     "wasYours": false, "completed": false, "weeklyCoins": 5, "latitude": 51.498, "longitude": -0.05,
     "ledger": {"placesFound": 7, "creaturesDefeated": 4, "runesCut": 1, "questsDone": 3,
                "firstPassed": "2026-08-06T09:00:00Z", "lastPassed": "2026-10-03T18:12:00.5Z"}}
    """#

    func testADistrictWithItsLedgerDecodes() throws {
        let district = try decode(District.self, Self.districtJSON)
        XCTAssertEqual(district.id, "c0ffee00-0000-4000-8000-00000000e001")
        XCTAssertEqual(district.fullName, "Rotherhithe, the Riverlands")
        XCTAssertEqual(district.wholePercent, 47)
        XCTAssertEqual(district.progressLine, "47% explored")
        XCTAssertEqual(district.wayTiles, 66)
        XCTAssertEqual(district.ledger?.placesFound, 7)
        XCTAssertEqual(district.ledger?.questsDone, 3)
        XCTAssertNotNil(district.firstVisit)
        XCTAssertNotNil(district.lastVisit)
    }

    /// Until its roads are known a district has no percentage, only a count; under
    /// 10% (or with no title yet) it is in the fog.
    func testADistrictWithoutItsRoadsCountsTiles() throws {
        let district = try decode(District.self, #"""
        {"id": 12, "name": "Deptford", "kind": "town", "percent": null, "exploredTiles": 12, "yours": false, "wasYours": false,
         "completed": false, "weeklyCoins": 5, "latitude": 51.47, "longitude": -0.02}
        """#)
        XCTAssertEqual(district.id, "12", "a number id reads as text")
        XCTAssertNil(district.percent)
        XCTAssertNil(district.wholePercent)
        XCTAssertEqual(district.progressLine, "12 tiles explored")
        XCTAssertEqual(district.fullName, "Deptford, in the fog")
        XCTAssertNil(district.ledger)
    }

    func testTheListAndTheDistrictHereDecode() throws {
        let list = try decode([District].self, "[\(Self.districtJSON)]")
        XCTAssertEqual(list.map(\.name), ["Rotherhithe"])
        let none = try decode(District?.self, "null")
        XCTAssertNil(none, "outside every district the answer is null")
        let sparse = try decode(District.self, #"{"id": "x", "name": "Bermondsey"}"#)
        XCTAssertEqual(sparse.exploredTiles, 0)
        XCTAssertFalse(sparse.yours)
    }

    static let atlasJSON = #"""
    {"traces": [{"rideId": "66666666-6666-4666-8666-666666666666", "activity": "RIDE", "date": "2026-10-03T08:00:00Z",
                 "polyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"},
                {"rideId": "66666666-6666-4666-8666-666666666611", "activity": "WALK", "date": "2026-10-03", "polyline": "_p~iF~ps|U"}],
     "days": [{"date": "2026-10-03", "journeys": 2, "distanceMeters": 27400.5}, {"date": "2026-09-28", "journeys": 1, "distanceMeters": 5000}],
     "year": {"journeys": 3, "distanceMeters": 32400, "newTiles": 58, "creaturesDefeated": 6, "legendsDefeated": 1, "runesCut": 1,
              "districtsYours": 2, "deedsReached": ["Wayfarer", {"deed": "LEGS", "name": "Legs", "title": "Roadwise"}],
              "firsts": [{"kind": "FIRST_CREATURE", "date": "2026-09-28", "text": "First creature defeated: Fen Troll"},
                         {"kind": "HIGHEST_POINT", "date": "2026-10-03", "text": "Highest point: 134 m"}]}}
    """#

    func testTheAtlasDecodes() throws {
        let atlas = try decode(Atlas.self, Self.atlasJSON)
        XCTAssertEqual(atlas.traces.count, 2)
        XCTAssertEqual(atlas.traces[0].day, "2026-10-03")
        XCTAssertEqual(atlas.traces[0].path.count, 3)
        XCTAssertEqual(atlas.traces(on: "2026-10-03").count, 2)
        XCTAssertEqual(atlas.daysByKey["2026-10-03"]?.journeys, 2)
        XCTAssertEqual(atlas.year.legendsDefeated, 1)
        XCTAssertEqual(atlas.year.districtsYours, 2)
        XCTAssertEqual(atlas.year.deedsReached, ["Wayfarer", "Roadwise"], "deeds as names or as objects")
        XCTAssertEqual(atlas.year.firsts.map(\.kind), ["FIRST_CREATURE", "HIGHEST_POINT"])
        let empty = try decode(Atlas.self, "{}")
        XCTAssertTrue(empty.traces.isEmpty)
        XCTAssertEqual(empty.year.journeys, 0)
    }

    func testAFestivalArcDecodesAndAnOlderArcStillDoes() throws {
        let arc = try decode(StoryArc.self, #"""
        {"slug": "season-midsummer", "title": "Midsummer", "description": "The longest day.", "minLevel": 1, "unlocked": true,
         "track": "SEASON", "season": "MIDSUMMER", "endsAt": "2026-07-08T00:00:00Z",
         "quests": [{"slug": "m1", "sequence": 1, "title": "A Green Place", "description": "Ride to a park.", "state": "OPEN"}]}
        """#)
        XCTAssertTrue(arc.isSeason)
        XCTAssertEqual(SeasonCopy.name(arc.season), "Midsummer")
        XCTAssertNotNil(arc.endsAt)
        let older = try decode(StoryArc.self, #"""
        {"slug": "a", "title": "A", "description": "", "minLevel": 1, "unlocked": true, "track": "MAIN", "quests": []}
        """#)
        XCTAssertFalse(older.isSeason)
        XCTAssertNil(older.endsAt)
        let standing = try decode(StoryStanding.self, #"""
        {"arcTitle": "Midsummer", "stepsDone": 1, "stepsTotal": 3, "arcCompleted": false, "track": "SEASON", "season": "MIDSUMMER",
         "endsAt": "2026-07-08T00:00:00Z"}
        """#)
        XCTAssertTrue(standing.isSeason)
        // As the server sends it: the festival's day as `window`, no `endsAt`.
        let windowed = try decode(StoryStanding.self, #"""
        {"arcSlug": "season-midsummer", "arcTitle": "Midsummer", "window": "2026-06-24", "stepTitle": "A Green Place",
         "stepsDone": 1, "stepsTotal": 3, "arcCompleted": false, "nextTitle": "The Festival Chest"}
        """#)
        XCTAssertTrue(windowed.isSeason)
        XCTAssertEqual(windowed.closesAt, ISO8601.parse("2026-07-08T00:00:00Z"))
    }

    func testTheLookAndTheLooksOwnedDecode() throws {
        let inventory = try decode(InventoryState.self, #"""
        {"slots": [], "look": {"ink": "ink:sage", "markerFrame": "marker:rope", "crestFrame": null},
         "cosmetics": [{"itemId": "ink:sage", "kind": "INK", "name": "Sage", "color": "#56633F"}, "marker:rope",
                       {"id": "crest:legs-3", "name": "Legs III", "source": "DEED"}]}
        """#)
        XCTAssertEqual(inventory.look?.ink, "ink:sage")
        XCTAssertNil(inventory.look?.crestFrame)
        XCTAssertEqual(inventory.cosmetics?.count, 3)
        XCTAssertEqual(inventory.cosmetics(.ink).map(\.name), ["Sage"])
        XCTAssertEqual(inventory.cosmetics(.markerFrame).map(\.name), ["Rope"], "a bare id reads as a look")
        XCTAssertEqual(inventory.cosmetics(.crestFrame).first?.itemId, "crest:legs-3")
        XCTAssertTrue(inventory.look?.wears("sage", as: .ink) == true)
        XCTAssertEqual(CosmeticCatalog.inkHex("ink:sage", color: inventory.cosmetics?.first?.color), 0x56633F)
        XCTAssertEqual(CosmeticCatalog.inkHex("wizard_blue"), 0x3D5A99)
        XCTAssertEqual(CosmeticCatalog.inkHex("ink:ink"), 0x2E2A24)
        XCTAssertNil(CosmeticCatalog.inkHex("ink:mystery"))

        let older = try decode(InventoryState.self, #"{"slots": []}"#)
        XCTAssertNil(older.look)
        XCTAssertNil(older.cosmetics)
    }

    func testTheStallsLookOfferDecodes() throws {
        let stall = try decode(Stall.self, #"""
        {"open": true, "offers": [{"id": "w41-4", "kind": "COSMETIC", "itemId": "marker:laurel", "name": "Laurel frame",
                                   "text": "A laurel round your marker.", "price": 250, "bought": false}]}
        """#)
        XCTAssertEqual(stall.offers.first?.isCosmetic, true)
        XCTAssertEqual(stall.offers.first?.lookKind, .markerFrame)
        XCTAssertFalse(SampleData.sampleStall.offers[0].isCosmetic)
    }

    func testLookChoiceSendsOnlyWhatChanges() throws {
        let data = try JSONCoding.encode(LookChoice(.ink, "ink:gold"))
        XCTAssertEqual(String(bytes: data, encoding: .utf8), #"{"ink":"ink:gold"}"#)
    }

    func testPlaceLoreIsReadFromTheTags() throws {
        let place = try decode(Discovery.self, #"""
        {"id": "11111111-1111-4111-8111-111111111111", "name": "Southwark Park", "category": "PARK", "latitude": 51.49,
         "longitude": -0.05, "source": "OSM", "discoveredByUser": true,
         "tags": {"wikidata": "Q7570920", "lore": "park in Rotherhithe"}}
        """#)
        XCTAssertEqual(place.lore, "park in Rotherhithe")
        XCTAssertEqual(place.loreLine, "From Wikidata: park in Rotherhithe")
        let without = try decode(Discovery.self, #"""
        {"id": "11111111-1111-4111-8111-111111111112", "name": "A Pub", "category": "PUB", "latitude": 51.49,
         "longitude": -0.05, "source": "OSM", "discoveredByUser": false, "tags": {"lore": "  "}}
        """#)
        XCTAssertNil(without.loreLine)
    }

    func testJourneysEndCarriesItsDistricts() throws {
        let summary = try JSONCoding.decode(AdventureSummary.self, from: try JSONCoding.encode(SampleData.sampleAdventureSummary))
        XCTAssertNil(summary.districts, "an older summary has none")
        XCTAssertNil(summary.districtPay)

        let outcome = try decode([DistrictOutcome].self, #"""
        [{"id": "e1", "name": "Bermondsey", "title": "the Market Quarter", "percent": 51.2, "newTiles": 3, "becameYours": true, "completed": false},
         {"id": "e2", "name": "Rotherhithe", "title": "the Riverlands", "percent": null, "newTiles": 2, "becameYours": false, "completed": true}]
        """#)
        var withDistricts = SampleData.sampleAdventureSummary
        withDistricts.districts = outcome
        withDistricts.districtPay = try decode(DistrictPay.self, #"{"coins": 10, "districts": ["Rotherhithe", "Bermondsey"]}"#)
        let again = try JSONCoding.decode(AdventureSummary.self, from: try JSONCoding.encode(withDistricts))
        XCTAssertEqual(again.districtsMadeYours, ["Bermondsey"])
        XCTAssertEqual(again.districtsCompleted, ["Rotherhithe"])
        XCTAssertEqual(again.districtPay?.coins, 10)
        XCTAssertEqual(DistrictCopy.outcome(outcome[0]), "Bermondsey, the Market Quarter · 3 new tiles · 51% explored")
        XCTAssertEqual(DistrictCopy.pay(again.districtPay!), "Your districts paid 10 coins this week: Rotherhithe, Bermondsey.")
    }
}
