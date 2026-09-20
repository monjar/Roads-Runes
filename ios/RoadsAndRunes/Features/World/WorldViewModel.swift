import Foundation
import MapKit
import Observation
import RoadsAndRunesCore

/// The World as a maps-app home: fog of war and discoveries from the server,
/// plus place search, tapped base-map POIs and dropped pins. Quests live on
/// the Quests tab.
@MainActor
@Observable
final class WorldViewModel {
    private(set) var snapshot: WorldSnapshot?
    private(set) var cells: [CellRender] = []
    var center: Coordinate?
    var camera: MapCamera?
    private(set) var visibleBox: BoundingBox?

    var selectedPlace: Place?
    /// A chest, piece or monster the rider tapped; the card says how to beat it.
    var selectedObject: WorldObject?
    private(set) var results: [Place] = []
    private(set) var resultsTitle: String?
    private(set) var activeShortcut: PlaceShortcut?
    private(set) var isSearching = false
    var error: String?

    let search = PlaceSearch()

    private let container: AppContainer
    private var lastLoadedCenter: Coordinate?
    private let fogGrid: FogGrid

    init(container: AppContainer) {
        self.container = container
        self.fogGrid = FogGrid(indexing: container.cellIndexing)
    }

    var units: Units { container.session.units }
    var position: Coordinate? { container.location.lastFix?.coordinate }

    // MARK: Server world (fog + discoveries)

    func load(around coordinate: Coordinate, force: Bool = false) async {
        await loadObjects(force: force)
        if !force, let last = lastLoadedCenter, GeoMath.distance(last, coordinate) < 1000 { return }
        do {
            let world = try await container.api.world(center: coordinate, radiusMeters: 6000)
            snapshot = world
            lastLoadedCenter = coordinate
            rebuildCells()
            container.rideRecorder.setKnownCells(Set(world.cells.filter { $0.state == .visited || $0.state == .explored }.map(\.h3)))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Merges the server's cells with what the current ride has uncovered so the fog clears live.
    /// With the fog switched off on the server, a ride must not paint hexes either:
    /// they were a readout nobody could act on, so the map is plain until they are a game.
    func rebuildCells() {
        guard let snapshot, snapshot.isEnabled(FeatureFlag.fogOfWar) else {
            cells = []
            return
        }
        cells = fogGrid.render(serverCells: snapshot.cells, localStates: container.rideRecorder.localCellStates)
    }

    func regionChanged(_ box: BoundingBox) {
        visibleBox = box
        search.focus(on: box)
    }

    // MARK: Markers

    var markers: [MapMarker] {
        var out: [MapMarker] = mysteries.map {
            MapMarker(id: "discovery-\($0.id.uuidString)", coordinate: $0.coordinate, kind: .discovery, title: $0.name)
        }
        out += results.filter { $0.id != selectedPlace?.id }.map {
            MapMarker(id: "result-\($0.id)", coordinate: $0.coordinate, kind: .result, title: $0.name)
        }
        if let selectedPlace {
            out.append(MapMarker(id: "place-\(selectedPlace.id)", coordinate: selectedPlace.coordinate, kind: .place, title: selectedPlace.name))
        }
        out += worldObjects.map { object in
            MapMarker(id: "object-\(object.id.uuidString)", coordinate: object.coordinate, kind: Self.markerKind(for: object), title: object.name)
        }
        return out
    }

    /// Chests, pieces and monsters around the *player*. The map can be dragged
    /// anywhere; what is out there is placed around where the rider actually is, so
    /// it is asked for by position and not by whatever the map is showing.
    private(set) var placedObjects: [WorldObject] = []
    private var objectsLoadedAt: Coordinate?

    func loadObjects(force: Bool = false) async {
        guard let here = position else { return }
        if !force, let last = objectsLoadedAt, GeoMath.distance(last, here) < 500 { return }
        objectsLoadedAt = here
        if let objects = try? await container.api.worldObjects(near: here, radiusMeters: 6000) {
            placedObjects = objects
        } else {
            objectsLoadedAt = nil
        }
    }

    var worldObjects: [WorldObject] {
        let known = Dictionary((placedObjects + (snapshot?.worldObjects ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return known.values.filter { $0.status == .spawned }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The "?" rings: off when the rider says so, and never more than the nearest
    /// thirty, because a hundred of them is wallpaper, not mystery.
    static let mysteryLimit = 30
    var mysteries: [DiscoverySummary] {
        guard container.mapPreferences.showMysteries, let all = snapshot?.discoveries else { return [] }
        guard all.count > Self.mysteryLimit, let here = center ?? position else { return all }
        return Array(all.sorted { GeoMath.distance(here, $0.coordinate) < GeoMath.distance(here, $1.coordinate) }.prefix(Self.mysteryLimit))
    }

    /// The nearest thing worth going out for, for the today strip.
    var nearestObject: (object: WorldObject, meters: Double)? {
        guard let here = position else { return nil }
        return worldObjects.map { ($0, GeoMath.distance(here, $0.coordinate)) }.min { $0.1 < $1.1 }.map { (object: $0.0, meters: $0.1) }
    }

    func open(_ object: WorldObject) {
        selectedPlace = nil
        selectedObject = object
        camera = MapCamera(center: object.coordinate)
    }

    static func markerKind(for object: WorldObject) -> MapMarker.Kind {
        if object.isBounty { return .bounty }
        switch object.kind {
        case .chest: return .chest
        case .collectable: return .collectable
        default: return .monster
        }
    }

    func tapMarker(_ marker: MapMarker) {
        if let object = worldObjects.first(where: { "object-\($0.id.uuidString)" == marker.id }) {
            selectedPlace = nil
            selectedObject = object
            camera = MapCamera(center: object.coordinate)
        } else if let place = results.first(where: { "result-\($0.id)" == marker.id }) {
            select(place, moveCamera: false)
        } else if let discovery = snapshot?.discoveries.first(where: { "discovery-\($0.id.uuidString)" == marker.id }) {
            select(Self.place(from: discovery), moveCamera: false)
        }
    }

    // MARK: Places

    func select(_ place: Place, moveCamera: Bool = true) {
        selectedObject = nil
        selectedPlace = place
        if moveCamera { camera = MapCamera(center: place.coordinate) }
        if place.address == nil { Task { await fillAddress(for: place) } }
    }

    /// A tap on a labelled place opens it; a tap on empty map closes the card.
    func tapMap(at coordinate: Coordinate, feature: MapFeature?) {
        if let feature {
            select(PlaceSearch.place(from: feature), moveCamera: false)
        } else {
            selectedPlace = nil
            selectedObject = nil
        }
    }

    func dropPin(at coordinate: Coordinate) {
        let pin = Place(
            id: String(format: "pin-%.5f,%.5f", coordinate.latitude, coordinate.longitude),
            name: "Dropped pin", category: nil, address: nil, symbol: "mappin",
            coordinate: coordinate, source: .pin
        )
        select(pin, moveCamera: false)
    }

    func closePlace() { selectedPlace = nil }
    func closeObject() { selectedObject = nil }

    /// A world object as somewhere to go: the planner takes a place.
    static func place(for object: WorldObject) -> Place {
        Place(
            id: "object-\(object.id.uuidString)", name: object.name, category: object.anchorName, address: nil,
            symbol: object.kind == .monster ? "flame.fill" : (object.kind == .chest ? "shippingbox.fill" : "sparkles"),
            coordinate: object.coordinate, source: .pin
        )
    }

    func locateMe() {
        guard let position else { return }
        camera = MapCamera(center: position, zoom: 15)
    }

    private func fillAddress(for place: Place) async {
        guard let address = await PlaceSearch.address(of: place.coordinate), selectedPlace?.id == place.id else { return }
        selectedPlace?.address = address
    }

    // MARK: Search

    func runShortcut(_ shortcut: PlaceShortcut) async {
        guard activeShortcut != shortcut else { return clearResults() }
        activeShortcut = shortcut
        await runSearch(shortcut.query, title: shortcut.title)
    }

    func submit(_ text: String) async {
        activeShortcut = nil
        await runSearch(text, title: "“\(text)”")
    }

    func pick(_ completion: MKLocalSearchCompletion) async {
        guard let place = try? await search.resolve(completion) else { return }
        clearResults()
        select(place)
    }

    func clearResults() {
        results = []
        resultsTitle = nil
        activeShortcut = nil
    }

    private func runSearch(_ text: String, title: String) async {
        selectedPlace = nil
        resultsTitle = title
        results = []
        isSearching = true
        defer { isSearching = false }
        let around = position ?? center
        let box = visibleBox ?? around.map {
            BoundingBox(minLat: $0.latitude - 0.02, minLon: $0.longitude - 0.035, maxLat: $0.latitude + 0.02, maxLon: $0.longitude + 0.035)
        }
        // MapKit can list the same place twice; list and marker ids must stay unique.
        var seen = Set<String>()
        let found = ((try? await search.search(text, in: box)) ?? []).filter { seen.insert($0.id).inserted }
        guard resultsTitle == title else { return }  // a newer search replaced this one
        if let origin = around {
            results = found.sorted { GeoMath.distance(origin, $0.coordinate) < GeoMath.distance(origin, $1.coordinate) }
        } else {
            results = found
        }
        if results.count >= 2 {
            camera = MapCamera(fit: results.prefix(12).map(\.coordinate), padding: UIEdgeInsets(top: 190, left: 50, bottom: 400, right: 50))
        } else if let first = results.first {
            camera = MapCamera(center: first.coordinate)
        }
    }

    static func place(from discovery: DiscoverySummary) -> Place {
        let kind = discovery.category == .unknown ? "Discovery" : discovery.category.rawValue.capitalized
        return Place(
            id: "discovery-\(discovery.id.uuidString)",
            name: discovery.name,
            category: "\(kind) · \(discovery.discoveredByUser ? "discovered" : "a mystery")",
            address: nil,
            symbol: DiscoveryIcon.symbol(for: discovery.category),
            coordinate: discovery.coordinate,
            source: .discovery(discovery.id)
        )
    }
}
