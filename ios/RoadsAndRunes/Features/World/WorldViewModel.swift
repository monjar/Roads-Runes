import Foundation
import MapKit
import Observation
import RoadsAndRunesArt
import RoadsAndRunesCore
import UIKit

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
    /// A chest, piece or monster the rider tapped; the card says what it wants.
    var selectedObject: WorldObject? {
        didSet { if selectedObject?.id != oldValue?.id { readGround(round: selectedObject) } }
    }
    /// How much of the ground round the selected creature is new to the player, for its card.
    private(set) var groundRound: GroundRound?

    struct GroundRound: Equatable {
        let objectId: UUID
        let unread: Int
        let of: Int
    }
    private(set) var results: [Place] = []
    private(set) var resultsTitle: String?
    private(set) var activeShortcut: PlaceShortcut?
    private(set) var isSearching = false
    var error: String?
    /// The chest or piece being opened right now, while the server is asked.
    private(set) var claiming: UUID?
    /// Why it would not open, said on its card.
    var claimError: String?
    /// What was just opened or picked up, for a few seconds.
    private(set) var recentClaim: WorldObject?
    /// The quest that opening it finished, if it finished one.
    private(set) var recentQuestTitle: String?
    /// A second line for the claim: where the piece's set stands, or that it is whole.
    private(set) var recentClaimDetail: String?
    /// The quest whose marker was tapped, to be opened where quests live.
    var openedQuestMarker: UUID?
    private var claimToast: Task<Void, Never>?
    /// What has already been pointed out for being within reach, so its card opens once.
    private var announced: Set<UUID> = []

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
        // A chest sits on the place it is anchored to. Two markers on one spot meant the
        // tap went to whichever the map picked, and the "?" often won.
        let objects = worldObjects
        var out: [MapMarker] = mysteries
            .filter { place in !objects.contains { GeoMath.distance($0.coordinate, place.coordinate) < 5 } }
            .map { MapMarker(id: "discovery-\($0.id.uuidString)", coordinate: $0.coordinate, kind: .discovery, title: $0.name) }
        out += results.filter { $0.id != selectedPlace?.id }.map {
            MapMarker(id: "result-\($0.id)", coordinate: $0.coordinate, kind: .result, title: $0.name)
        }
        if let selectedPlace {
            out.append(MapMarker(id: "place-\(selectedPlace.id)", coordinate: selectedPlace.coordinate, kind: .place, title: selectedPlace.name))
        }
        // Where the quests in hand go: sent by the server all along, and never drawn.
        out += (snapshot?.questMarkers ?? []).map { marker in
            MapMarker(
                id: "quest-\(marker.questId.uuidString)", coordinate: marker.coordinate,
                kind: marker.status == .active || marker.status == .accepted ? .questActive : .quest, title: marker.title
            )
        }
        out += objects.map { object in
            MapMarker(
                id: "object-\(object.id.uuidString)", coordinate: object.coordinate, kind: Self.markerKind(for: object),
                title: object.name, inReach: isWithinReach(object), mark: .of(object)
            )
        }
        return out
    }

    // MARK: Reaching for it

    /// Close enough to open it or pick it up from where the player is standing.
    func isWithinReach(_ object: WorldObject) -> Bool {
        guard let here = position else { return false }
        return object.isWithinReach(of: here)
    }

    /// The ring drawn round the player: how far they can reach, shown once there is
    /// something near enough to walk up to.
    static let reachRingWithinMeters = 300.0
    var reach: MapReach? {
        guard let here = position else { return nil }
        let near = worldObjects.filter { $0.reachMeters != nil && GeoMath.distance(here, $0.coordinate) <= Self.reachRingWithinMeters }
        guard let meters = near.compactMap(\.reachMeters).max() else { return nil }
        return MapReach(center: here, meters: meters)
    }

    /// Walking up to a chest should not need the player to find its marker with a
    /// thumb: the first time one comes within reach, its card opens.
    /// Returns whether it opened one.
    @discardableResult
    func noticeReach() -> Bool {
        guard let here = position else { return false }
        let within = worldObjects.filter { $0.isWithinReach(of: here) }
        announced.formIntersection(within.map(\.id))
        guard selectedObject == nil, selectedPlace == nil, resultsTitle == nil, claiming == nil else { return false }
        guard let nearest = within.filter({ !announced.contains($0.id) }).min(by: { GeoMath.distance(here, $0.coordinate) < GeoMath.distance(here, $1.coordinate) }) else { return false }
        announced.insert(nearest.id)
        claimError = nil
        selectedObject = nearest
        return true
    }

    /// Open the chest, or pick the piece up. The server has the last word on whether
    /// the player is close enough; what it says when they are not goes on the card.
    func claim(_ object: WorldObject) async {
        guard claiming == nil else { return }
        guard let fix = container.location.lastFix else {
            claimError = "Waiting for your location"
            return
        }
        claiming = object.id
        claimError = nil
        defer { claiming = nil }
        do {
            let result = try await container.api.claimWorldObject(
                id: object.id,
                WorldObjectClaimRequest(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, horizontalAccuracyMeters: fix.horizontalAccuracy)
            )
            take(result.object)
            selectedObject = nil
            let detail = result.setCompleted.map { "\($0.name) complete · \(LoreCopy.earned($0.bonusAC))" } ?? result.object.setStanding?.line
            show(claimed: result.object, quest: result.questCompleted?.title, detail: detail)
            container.analytics.track(.worldObjectClaimed, properties: ["kind": object.kind.rawValue, "name": object.name, "method": "TAP"])
            await container.session.refreshCharacter()
        } catch let error as APIError where error.errorCode == APIErrorCode.objectGone {
            // Already opened, on a ride or another phone: it should not still be on the map.
            var gone = object
            gone.status = .claimed
            take(gone)
            claimError = error.localizedDescription
        } catch {
            claimError = error.localizedDescription
        }
    }

    /// A lamp left out (docs/COMBAT.md): one thing comes to the nearest named place
    /// within 250 m of the spot, and the coins go only if something comes.
    static let lampCost = 50
    private(set) var leavingLamp = false
    var lampError: String?

    func leaveLamp(at place: Place) async {
        guard !leavingLamp else { return }
        leavingLamp = true
        lampError = nil
        defer { leavingLamp = false }
        do {
            let came = try await container.api.lure(at: place.coordinate)
            for object in came { take(object) }
            if let first = came.first {
                selectedPlace = nil
                open(first)
            }
            container.analytics.track(.worldObjectClaimed, properties: ["kind": "LAMP", "name": place.name, "method": "LAMP"])
            await container.session.refreshCharacter()
        } catch {
            lampError = error.localizedDescription
        }
    }

    /// The object as the server now has it replaces whatever the map was holding.
    private func take(_ object: WorldObject) {
        placedObjects.removeAll { $0.id == object.id }
        placedObjects.append(object)
    }

    private func show(claimed object: WorldObject, quest: String?, detail: String?) {
        recentClaim = object
        recentQuestTitle = quest
        recentClaimDetail = detail
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        claimToast?.cancel()
        claimToast = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.recentClaim = nil
            self?.recentQuestTitle = nil
            self?.recentClaimDetail = nil
        }
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
            container.nudges.note(objects: objects, around: here)
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
        claimError = nil
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
            claimError = nil
            selectedObject = object
            camera = MapCamera(center: object.coordinate)
        } else if marker.id.hasPrefix("quest-"), let questId = UUID(uuidString: String(marker.id.dropFirst(6))) {
            openedQuestMarker = questId
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
        lampError = nil
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
    func closeObject() {
        selectedObject = nil
        claimError = nil
    }

    /// A world object as somewhere to go: the planner takes a place.
    static func place(for object: WorldObject) -> Place {
        Place(
            id: "object-\(object.id.uuidString)", name: object.name, category: object.anchorName, address: nil,
            symbol: object.kind == .monster ? "flame.fill" : (object.kind == .chest ? "shippingbox.fill" : "sparkles"),
            coordinate: object.coordinate, source: object.kind == .monster ? .quarry(object.id) : .pin
        )
    }

    /// New ground counts against a creature inside its ground: the card says how
    /// much of the ground round it is still unread. Asked of the server each time,
    /// whether or not the fog is drawn.
    private func readGround(round object: WorldObject?) {
        groundRound = nil
        guard let object, object.monster?.foughtByEffort == true else { return }
        let reach = container.session.config?.combat?.groundMeters ?? 1000
        let resolution = container.session.config?.h3Resolution ?? ExplorationDefaults.h3Resolution
        let indexing = container.cellIndexing
        Task { [weak self] in
            let dLat = reach / 111_195, dLon = reach / (111_195 * max(0.2, cos(object.latitude * .pi / 180)))
            let box = BoundingBox(minLat: object.latitude - dLat, minLon: object.longitude - dLon,
                                  maxLat: object.latitude + dLat, maxLon: object.longitude + dLon)
            guard let self, let read = try? await self.container.api.exploration(in: box), read.h3Resolution == resolution else { return }
            let known = Set(read.cells.filter { $0.state == .visited || $0.state == .explored }.map(\.h3))
            let round = Self.cells(round: object.coordinate, within: reach, resolution: resolution, indexing: indexing)
            guard !round.isEmpty, self.selectedObject?.id == object.id else { return }
            self.groundRound = GroundRound(objectId: object.id, unread: round.subtracting(known).count, of: round.count)
        }
    }

    /// The cells whose centres lie within `meters` of a point, grown ring by ring.
    static func cells(round centre: Coordinate, within meters: Double, resolution: Int, indexing: any CellIndexing) -> Set<String> {
        let first = indexing.cell(latitude: centre.latitude, longitude: centre.longitude, resolution: resolution)
        var inside: Set<String> = [first]
        var frontier = [first]
        while !frontier.isEmpty, inside.count < 2000 {
            var next: [String] = []
            for cell in frontier {
                for n in indexing.neighbours(of: cell) where !inside.contains(n) && GeoMath.distance(indexing.center(of: n), centre) <= meters {
                    inside.insert(n)
                    next.append(n)
                }
            }
            frontier = next
        }
        return inside
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
