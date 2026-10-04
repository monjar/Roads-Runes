import XCTest
@testable import RoadsAndRunesCore

/// The live fold says what the server would, a little on the low side, and says
/// each thing once.
final class FightTrackerTests: XCTestCase {
    private let home = Coordinate(latitude: 51.4906, longitude: -0.0316)

    private func troll(hold: Int, wants: [String], minds: [String] = ["CLIMB"]) -> WorldObject {
        WorldObject(
            id: UUID(), kind: .monster, latitude: home.latitude, longitude: home.longitude, name: "Fen Troll", rewardAC: 60,
            expiresAt: Date().addingTimeInterval(86_400),
            monster: MonsterInfo(hp: 100, holdMax: hold, holdLeft: hold, wants: wants, minds: minds)
        )
    }

    private func setup(known: Set<String> = []) -> FightTracker.Setup {
        FightTracker.Setup(constants: CombatConstants(), sheet: CharacterSheet(), activity: .ride, knownCells: known,
                           groundResolution: 9, indexing: FakeCellIndexing())
    }

    /// West to east through the creature, a fix every 10 m.
    private func past(_ tracker: inout EncounterTracker, from west: Double = 900, length: Double = 2600) -> [FightNews] {
        var news: [FightNews] = []
        let start = GeoMath.destination(from: home, bearingDegrees: 270, distanceMeters: west)
        for k in 0...Int(length / 10) {
            let p = GeoMath.destination(from: start, bearingDegrees: 90, distanceMeters: Double(k) * 10)
            news += tracker.update(position: p, timestamp: Date(timeIntervalSince1970: Double(k) * 2), altitude: 10,
                                   elevationGainMeters: 0, accuracy: 5).news
        }
        return news
    }

    func testPassingByLoosensWhatDoesNotWantTheRoadAndSaysSoOnce() {
        let thing = troll(hold: 220, wants: ["GROUND", "WORD"])
        // Everything round home already read: only the road lands.
        var tracker = EncounterTracker(objects: [thing], activity: .ride, fights: setup(known: allCells()))
        let news = past(&tracker)
        XCTAssertEqual(news.first, .engaged(thing))
        XCTAssertEqual(news.filter { $0 == .loosened(thing) }.count, 1)
        XCTAssertFalse(news.contains(.seenOff(thing)))
        let left = try? XCTUnwrap(tracker.fights?.holdFraction(of: thing.id))
        XCTAssertLessThan(left ?? 1, 1)
        XCTAssertTrue(tracker.pendingEvents.isEmpty, "an outing past it sends nothing; the server reads the trace")
    }

    func testTheRoadSeesOffAThingThatWantsIt() {
        let thing = troll(hold: 10, wants: ["ROAD", "WORD"])
        var tracker = EncounterTracker(objects: [thing], activity: .ride, fights: setup(known: allCells()))
        let news = past(&tracker)
        XCTAssertEqual(news.filter { $0 == .seenOff(thing) }.count, 1)
        XCTAssertFalse(news.contains(.loosened(thing)))
        XCTAssertTrue(tracker.claimedIDs.contains(thing.id))
    }

    func testAWordWrittenNearItLandsAndIsSentForTheServerToPlace() throws {
        let thing = troll(hold: 400, wants: ["GROUND", "WORD"])
        var tracker = EncounterTracker(objects: [thing], activity: .ride, fights: setup(known: allCells()))
        _ = past(&tracker, from: 300, length: 300)
        let result = try XCTUnwrap(tracker.markLore(thing.id, at: home, timestamp: Date(), note: "A troll asleep by the water.", photoTaken: false))
        XCTAssertEqual(result.news, [.landed(thing, kind: "WORD")])
        XCTAssertEqual(tracker.pendingEvents.count, 1)
        XCTAssertFalse(tracker.claimedIDs.contains(thing.id), "the word loosens; it does not claim by itself")
        // Too few words is not the word.
        let again = try XCTUnwrap(tracker.markLore(thing.id, at: home, timestamp: Date(), note: "troll", photoTaken: false))
        XCTAssertTrue(again.news.isEmpty)
    }

    func testTheOldCheckIsNeverRunOnAThingWithAHold() {
        var thing = troll(hold: 100, wants: ["GROUND", "WORD"])
        thing.monster?.killMethods = [KillMethod(method: .climb, params: ["gainMeters": .number(0)], hint: "x")]
        var tracker = EncounterTracker(objects: [thing], activity: .ride, fights: setup(known: allCells()))
        let news = past(&tracker, from: 300, length: 600)
        XCTAssertFalse(tracker.claimedIDs.contains(thing.id), "a zero-metre climb would have claimed it the old way")
        XCTAssertEqual(news.first, .engaged(thing))
    }

    func testWithoutAFightSetupTheRideSaysNothingOfFights() {
        let thing = troll(hold: 100, wants: ["ROAD", "WORD"])
        var tracker = EncounterTracker(objects: [thing], activity: .ride)
        XCTAssertNil(tracker.fights)
        XCTAssertTrue(past(&tracker).isEmpty)
    }

    func testTheHoldIsDrawnInTenths() {
        let status = EncounterStatus(object: troll(hold: 100, wants: []), distanceMeters: 0, hold: 0.31)
        XCTAssertEqual(status.holdTenths, 4)
        XCTAssertEqual(EncounterStatus(object: troll(hold: 100, wants: []), distanceMeters: 0, hold: 1).holdTenths, 10)
        XCTAssertNil(EncounterStatus(object: troll(hold: 100, wants: []), distanceMeters: 0).holdTenths)
    }

    /// Every fake cell for a few kilometres round home.
    private func allCells() -> Set<String> {
        let fake = FakeCellIndexing()
        var out: Set<String> = []
        for dLat in stride(from: -0.03, through: 0.03, by: 0.001) {
            for dLon in stride(from: -0.05, through: 0.05, by: 0.001) {
                out.insert(fake.cell(latitude: home.latitude + dLat, longitude: home.longitude + dLon, resolution: 9))
            }
        }
        return out
    }
}
