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

    /// A legend in reach (0.8.0) outranks a creature, and a creature nearer than it;
    /// the bounty still comes first, and a legend out of reach or asleep is passed over.
    func testALegendInReachOutranksACreature() {
        let creature = object(.monster, metersNorth: 300)
        var legend = SampleData.sampleLegend
        let far = GeoMath.destination(from: here, bearingDegrees: 90, distanceMeters: 2500)
        legend.latitude = far.latitude
        legend.longitude = far.longitude
        let next = NextUp.choose(character: character(), objects: [creature], position: here, legend: legend) { _ in false }
        guard case .legend(let picked, let meters) = next else { return XCTFail("\(next)") }
        XCTAssertEqual(picked.id, legend.id)
        XCTAssertEqual(meters, 2500, accuracy: 5)

        let bounty = object(.monster, metersNorth: 900, bounty: true)
        guard case .creature(let first, _) = NextUp.choose(character: character(), objects: [creature, bounty], position: here, legend: legend,
                                                           inReach: { _ in false }) else { return XCTFail("the bounty") }
        XCTAssertEqual(first.id, bounty.id)

        let away = GeoMath.destination(from: here, bearingDegrees: 90, distanceMeters: NextUp.legendReachMeters + 1000)
        legend.latitude = away.latitude
        legend.longitude = away.longitude
        guard case .creature(let instead, _) = NextUp.choose(character: character(), objects: [creature], position: here, legend: legend,
                                                             inReach: { _ in false }) else { return XCTFail("out of reach") }
        XCTAssertEqual(instead.id, creature.id)

        legend.latitude = far.latitude
        legend.longitude = far.longitude
        legend.status = LegendStatus.dormant
        guard case .creature = NextUp.choose(character: character(), objects: [creature], position: here, legend: legend,
                                             inReach: { _ in false }) else { return XCTFail("asleep") }
        // With nothing else near, the legend in reach is next.
        legend.status = LegendStatus.awake
        guard case .legend = NextUp.choose(character: character(), objects: [], position: here, legend: legend, inReach: { _ in false }) else {
            return XCTFail("alone")
        }
    }

    func testNothingNearSendsThePlayerToTheBoard() {
        let far = object(.monster, metersNorth: NextUp.nearMeters + 500)
        XCTAssertEqual(NextUp.choose(character: character(), objects: [far], position: here) { _ in false }, .quests)
        XCTAssertEqual(NextUp.choose(character: character(), objects: [], position: nil) { _ in false }, .quests)
    }
}
