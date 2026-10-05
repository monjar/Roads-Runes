import RoadsAndRunesArt
import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// 0.8.0 in the app: the legend on the World map and in a journey's fight, its one
/// free move, a treasure map's clue, and the signature haptics as CoreHaptics sees them.
@MainActor
final class LegendsAppTests: XCTestCase {
    private var clock: TimeInterval = 0

    private func ready(_ api: MockAPI = MockAPI()) async -> AppContainer {
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        return container
    }

    func testTheLegendIsOnTheWorldMapAndOpensItsPage() async throws {
        let container = await ready()
        await container.legends.refresh()
        let legend = try XCTUnwrap(container.legends.awake)
        let model = WorldViewModel(container: container)
        let marker = try XCTUnwrap(model.markers.first { $0.id == "legend-\(legend.id.uuidString)" })
        XCTAssertEqual(marker.kind, .legend)
        XCTAssertEqual(marker.mark, .legend(icon: "fogDragon", speciesId: "fog-dragon"))
        model.tapMarker(marker)
        XCTAssertEqual(model.openedLegend?.id, legend.id)
        XCTAssertFalse(model.worldObjects.contains(where: \.isLair), "a lair is never a thing to pass or fight")
        let place = WorldViewModel.place(for: legend)
        XCTAssertEqual(place.source, .quarry(legend.id), "a ride planned to it is for it")
    }

    func testTheLegendMovesOnceAndSaysSoTheSecondTime() async throws {
        let container = await ready()
        await container.legends.refresh()
        let legend = try XCTUnwrap(container.legends.awake)
        await container.legends.loadPage(id: legend.id)
        XCTAssertEqual(container.legends.page?.journeys?.count, 3)
        let first = await container.legends.move(legend)
        XCTAssertTrue(first)
        XCTAssertEqual(container.legends.awake?.moved, true)
        XCTAssertNotEqual(container.legends.awake?.coordinate, legend.coordinate)
        XCTAssertEqual(container.legends.page?.journeys?.count, 3, "the page keeps its journeys")
        let second = await container.legends.move(legend)
        XCTAssertFalse(second)
        XCTAssertEqual(container.legends.error, "You've moved it once already. It stays where it is now.")
    }

    /// The legend is fought beside the world's things: in the ride's tracker, on its
    /// own on the ride map, and never among the objects on the way.
    func testTheRideFightsTheLegendBesideTheWorld() async throws {
        let api = MockAPI()
        let container = await ready(api)
        let package = try await api.routePackage(id: SampleData.routeId)
        let path = package.route.path
        var legend = SampleData.sampleLegend
        legend.latitude = path[6].latitude
        legend.longitude = path[6].longitude
        api.setLegends(LegendsState(awake: legend))
        let recorder = container.rideRecorder
        await recorder.start(package: package, quest: nil, bikeId: nil)
        XCTAssertEqual(recorder.legendOnMap?.id, legend.id)
        XCTAssertEqual(recorder.legendOnMap?.monster?.phase, 2)
        XCTAssertFalse(recorder.objectsOnMap.contains { $0.isLegend || $0.isLair })
        for point in path.prefix(7) {
            clock += 20
            recorder.handle(fix: LocationFix(coordinate: point, timestamp: SampleData.referenceDate.addingTimeInterval(clock), altitude: 10,
                                             horizontalAccuracy: 5, speed: 5))
        }
        XCTAssertEqual(recorder.encounter?.object.id, legend.id, "standing on it, it is what the ride is about")
        XCTAssertEqual(container.worldCache.load()?.legend?.id, legend.id, "kept for a journey with no signal")
        recorder.discard()
    }

    func testATreasureMapsClueIsSaidAndKept() async throws {
        let container = await ready()
        let clue = SampleData.sampleClue
        let result = ConsumableUseResult(clue: clue.clue, treasureId: clue.treasureId)
        let stack = ConsumableStack(id: ConsumableId.treasureMap, name: "Treasure map", text: "", count: 1)
        XCTAssertEqual(GearModel.line(for: result, used: stack), "Treasure map used. Follow its clue to the buried treasure.")
        XCTAssertEqual(ConsumableRow.verb(stack), "Use treasure map")
        container.legends.opened(clue)
        XCTAssertEqual(container.legends.clues.map(\.clue), [clue.clue])
        await container.legends.refreshClues()
        XCTAssertTrue(container.legends.clues.isEmpty, "the mock buried nothing: the server's word wins")
    }

    /// Every signature pattern is one CoreHaptics accepts.
    func testEverySignaturePatternIsAValidCoreHapticsPattern() throws {
        for haptic in SignatureHaptic.allCases {
            XCTAssertNoThrow(try SignatureHapticsPlayer.pattern(haptic.pattern), haptic.rawValue)
        }
        // Nothing plays from tests.
        _ = AppContainer(api: MockAPI(), inMemory: true)
        XCTAssertFalse(SignatureHapticsPlayer.shared.enabled)
    }
}
