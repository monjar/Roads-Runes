import Foundation

/// The game layer of a ride in progress, saved with it (0.7.2) so that crash
/// recovery puts back the fights and the encounters along with the route: what
/// was in play, what was claimed, the events still to send, and what the phone
/// needs to fold the fights again.
public struct RideGameState: Codable, Hashable, Sendable {
    public var objects: [WorldObject]
    public var claimedIDs: [UUID]
    /// The phone's word on what it claimed, still to go with the ride's completion.
    public var events: [EncounterEvent]
    public var quarryId: UUID?
    public var sightMeters: Double?
    /// Present when the ride was following fights (effort is damage).
    public var fights: FightSetupState?

    public init(objects: [WorldObject], claimedIDs: [UUID] = [], events: [EncounterEvent] = [], quarryId: UUID? = nil,
                sightMeters: Double? = nil, fights: FightSetupState? = nil) {
        self.objects = objects
        self.claimedIDs = claimedIDs
        self.events = events
        self.quarryId = quarryId
        self.sightMeters = sightMeters
        self.fights = fights
    }
}

/// `FightTracker.Setup` without the cell index, which is the device's to supply.
public struct FightSetupState: Codable, Hashable, Sendable {
    /// The constants as `/config` sent them; the sheet's rules are applied on top.
    public var constants: CombatConstants
    public var sheet: CharacterSheet
    public var knownCells: [String]
    public var groundResolution: Int
    public var readBounds: BoundingBox?
    /// The creature the journey was planned for (0.9.0, Tiwaz); nil in an older snapshot.
    public var quarryId: UUID?

    public init(constants: CombatConstants, sheet: CharacterSheet, knownCells: [String], groundResolution: Int, readBounds: BoundingBox? = nil,
                quarryId: UUID? = nil) {
        self.constants = constants
        self.sheet = sheet
        self.knownCells = knownCells
        self.groundResolution = groundResolution
        self.readBounds = readBounds
        self.quarryId = quarryId
    }

    public init(_ setup: FightTracker.Setup) {
        self.init(constants: setup.constants, sheet: setup.sheet, knownCells: setup.knownCells.sorted(), groundResolution: setup.groundResolution,
                  readBounds: setup.readBounds, quarryId: setup.quarryId)
    }

    public func setup(activity: Activity, indexing: any CellIndexing) -> FightTracker.Setup {
        FightTracker.Setup(constants: constants, sheet: sheet, activity: activity, knownCells: Set(knownCells), groundResolution: groundResolution,
                           indexing: indexing, readBounds: readBounds, quarryId: quarryId)
    }
}

/// The last world loaded (0.7.2), kept beside the route packages so a ride that
/// starts with no signal still has its creatures, chests and pieces, the ground
/// already explored round them, and what the fight needs: the constants and the
/// character sheet. Each part is saved when it is loaded; the rest is kept.
public struct CachedWorld: Codable, Hashable, Sendable {
    public var savedAt: Date
    /// Where the objects were asked for, and how far round.
    public var center: Coordinate?
    public var radiusMeters: Double?
    public var objects: [WorldObject]
    /// Visited or explored cells at `h3Resolution`, read for `cellsBounds`.
    public var exploredCells: [String]?
    public var h3Resolution: Int?
    public var cellsBounds: BoundingBox?
    public var combat: CombatConstants?
    public var sheet: CharacterSheet?
    /// The legend awake when the world was last loaded (0.8.0), for a journey with no signal.
    public var legend: Legend?

    public init(savedAt: Date = Date(), center: Coordinate? = nil, radiusMeters: Double? = nil, objects: [WorldObject] = [],
                exploredCells: [String]? = nil, h3Resolution: Int? = nil, cellsBounds: BoundingBox? = nil,
                combat: CombatConstants? = nil, sheet: CharacterSheet? = nil) {
        self.savedAt = savedAt
        self.center = center
        self.radiusMeters = radiusMeters
        self.objects = objects
        self.exploredCells = exploredCells
        self.h3Resolution = h3Resolution
        self.cellsBounds = cellsBounds
        self.combat = combat
        self.sheet = sheet
    }

    /// What is still worth having round `position`: in the world, not gone by `now`,
    /// within `radiusMeters`.
    public func objects(near position: Coordinate, radiusMeters: Double, now: Date = Date()) -> [WorldObject] {
        objects.filter { $0.status == .spawned && $0.expiresAt > now && GeoMath.distance(position, $0.coordinate) <= radiusMeters }
    }

    /// The explored cells, when they were read at this resolution and the area they
    /// cover reaches `box`; the bounds are where they can be trusted.
    public func cells(resolution: Int, covering box: BoundingBox) -> (cells: Set<String>, bounds: BoundingBox)? {
        guard let exploredCells, h3Resolution == resolution, let read = cellsBounds,
              let overlap = read.intersection(box) else { return nil }
        return (Set(exploredCells), overlap)
    }
}

public extension BoundingBox {
    /// The part two boxes share, or nil when they do not meet.
    func intersection(_ other: BoundingBox) -> BoundingBox? {
        let box = BoundingBox(minLat: max(minLat, other.minLat), minLon: max(minLon, other.minLon),
                              maxLat: min(maxLat, other.maxLat), maxLon: min(maxLon, other.maxLon))
        return box.minLat < box.maxLat && box.minLon < box.maxLon ? box : nil
    }
}

/// `last-world.json` under `directory` (the route packages' folder), written atomically.
public struct FileWorldCacheStore: Sendable {
    public static let fileName = "last-world.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public func load() -> CachedWorld? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONCoding.decode(CachedWorld.self, from: data)
    }

    public func save(_ world: CachedWorld) throws {
        try FileStorage.ensureDirectory(directory)
        try JSONCoding.encode(world).write(to: fileURL, options: .atomic)
    }

    /// Changes one part and keeps the rest: the objects from one load, the ground from another.
    public func update(_ change: (inout CachedWorld) -> Void) throws {
        var world = load() ?? CachedWorld()
        change(&world)
        world.savedAt = Date()
        try save(world)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
