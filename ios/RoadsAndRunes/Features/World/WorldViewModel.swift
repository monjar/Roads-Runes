import Foundation
import Observation
import RoadsAndRunesCore

@MainActor
@Observable
final class WorldViewModel {
    private(set) var snapshot: WorldSnapshot?
    private(set) var cells: [CellRender] = []
    private(set) var nearbyQuests: [Quest] = []
    private(set) var stats: ExplorationStats?
    private(set) var isLoading = false
    var error: String?
    var selectedQuest: Quest?
    var center: Coordinate?

    private let container: AppContainer
    private var lastLoadedCenter: Coordinate?
    private let fogGrid: FogGrid

    init(container: AppContainer) {
        self.container = container
        self.fogGrid = FogGrid(indexing: container.cellIndexing)
    }

    var units: Units { container.session.units }

    func load(around coordinate: Coordinate, force: Bool = false) async {
        if !force, let last = lastLoadedCenter, GeoMath.distance(last, coordinate) < 1000 { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let world = try await container.api.world(center: coordinate, radiusMeters: 6000)
            snapshot = world
            lastLoadedCenter = coordinate
            rebuildCells()
            container.rideRecorder.setKnownCells(Set(world.cells.filter { $0.state == .visited || $0.state == .explored }.map(\.h3)))
            let page = try await container.api.quests(near: coordinate, status: .available)
            nearbyQuests = page.items
            container.persistence.cache(quests: page.items)
            stats = try? await container.api.explorationStats()
            error = nil
        } catch {
            self.error = error.localizedDescription
            if nearbyQuests.isEmpty { nearbyQuests = container.persistence.cachedQuests() }
        }
    }

    /// Merges the server's cells with what the current ride has uncovered so the fog clears live.
    func rebuildCells() {
        guard let snapshot else { return }
        cells = fogGrid.render(serverCells: snapshot.cells, localStates: container.rideRecorder.localCellStates)
    }

    var markers: [MapMarker] {
        guard let snapshot else { return [] }
        var out: [MapMarker] = snapshot.questMarkers.map {
            MapMarker(id: $0.questId.uuidString, coordinate: $0.coordinate, kind: $0.status == .active || $0.status == .accepted ? .questActive : .quest, title: $0.title)
        }
        out += snapshot.discoveries.map { MapMarker(id: $0.id.uuidString, coordinate: $0.coordinate, kind: .discovery, title: $0.name) }
        return out
    }

    func select(marker: MapMarker) {
        guard let id = UUID(uuidString: marker.id) else { return }
        if let quest = nearbyQuests.first(where: { $0.id == id }) {
            selectedQuest = quest
        } else {
            Task { selectedQuest = try? await container.api.quest(id: id) }
        }
    }
}
