import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// The World map's "Next up" picks the first thing that applies, in a fixed order.
final class NextUpTests: XCTestCase {
    private let here = Coordinate(latitude: 51.4900, longitude: -0.0400)

    private func object(_ kind: WorldObjectKind, metersNorth: Double, bounty: Bool = false) -> WorldObject {
        WorldObject(
            id: UUID(), kind: kind,
            latitude: here.latitude + metersNorth / 111_000, longitude: here.longitude,
            name: kind == .monster ? "Fen Troll" : "Iron chest", anchorName: "Stave Hill", bounty: bounty,
            rewardAC: 60, expiresAt: Date().addingTimeInterval(86_400)
        )
    }

    private func character(xp: Int = 1820, points: Int = 0) -> Character {
        var character = SampleData.sampleCharacter
        character.overallXP = xp
        character.unspentAbilityPoints = points
        return character
    }

    func testANewPlayerIsToldToGoOutFirst() {
        let next = NextUp.choose(character: character(xp: 0), objects: [object(.chest, metersNorth: 10)], position: here) { _ in true }
        XCTAssertEqual(next, .firstRide)
    }

    func testSomethingInReachComesBeforeASkillPoint() {
        let chest = object(.chest, metersNorth: 20)
        let next = NextUp.choose(character: character(points: 1), objects: [chest], position: here) { $0.id == chest.id }
        XCTAssertEqual(next, .inReach(chest))
    }

    func testASkillPointComesBeforeRidingSomewhere() {
        let next = NextUp.choose(character: character(points: 2), objects: [object(.monster, metersNorth: 500)], position: here) { _ in false }
        XCTAssertEqual(next, .skillPoints(2))
    }

    func testTheBountyBeatsANearerCreatureAndACreatureBeatsAChest() {
        let chest = object(.chest, metersNorth: 100)
        let creature = object(.monster, metersNorth: 400)
        let bounty = object(.monster, metersNorth: 900, bounty: true)
        let next = NextUp.choose(character: character(), objects: [chest, creature, bounty], position: here) { _ in false }
        guard case .creature(let picked, _) = next else { return XCTFail("\(next)") }
        XCTAssertEqual(picked.id, bounty.id)
        let without = NextUp.choose(character: character(), objects: [chest, creature], position: here) { _ in false }
        guard case .creature(let nearest, _) = without else { return XCTFail("\(without)") }
        XCTAssertEqual(nearest.id, creature.id)
    }

    func testNothingNearSendsThePlayerToTheBoard() {
        let far = object(.monster, metersNorth: NextUp.nearMeters + 500)
        XCTAssertEqual(NextUp.choose(character: character(), objects: [far], position: here) { _ in false }, .quests)
        XCTAssertEqual(NextUp.choose(character: character(), objects: [], position: nil) { _ in false }, .quests)
    }
}
