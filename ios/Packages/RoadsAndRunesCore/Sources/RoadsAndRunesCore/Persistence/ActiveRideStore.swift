import Foundation

/// Everything needed to offer Resume / Finish / Discard after a crash.
/// Persist it every few fixes and on every navigation state change.
public struct ActiveRideState: Codable, Hashable, Sendable {
    public var rideId: UUID?
    public var clientRideId: UUID
    public var questId: UUID?
    public var routeId: UUID?
    public var bikeId: UUID?
    public var navigationState: NavigationState
    public var startedAt: Date
    public var updatedAt: Date
    public var stats: RideSnapshot
    public var pendingCells: [String]
    public var visitedCells: [String]
    public var completedObjectiveIDs: [UUID]
    public var pendingObjectiveEvents: [ObjectiveEvent]
    public var lastFix: LocationFix?
    public var lastSegmentIndex: Int
    /// Custom adventure name; nil for quest rides.
    public var title: String?

    public init(
        rideId: UUID? = nil, clientRideId: UUID, questId: UUID? = nil, routeId: UUID? = nil, bikeId: UUID? = nil,
        navigationState: NavigationState, startedAt: Date, updatedAt: Date, stats: RideSnapshot,
        pendingCells: [String] = [], visitedCells: [String] = [], completedObjectiveIDs: [UUID] = [],
        pendingObjectiveEvents: [ObjectiveEvent] = [], lastFix: LocationFix? = nil, lastSegmentIndex: Int = 0,
        title: String? = nil
    ) {
        self.rideId = rideId
        self.clientRideId = clientRideId
        self.questId = questId
        self.title = title
        self.routeId = routeId
        self.bikeId = bikeId
        self.navigationState = navigationState
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stats = stats
        self.pendingCells = pendingCells
        self.visitedCells = visitedCells
        self.completedObjectiveIDs = completedObjectiveIDs
        self.pendingObjectiveEvents = pendingObjectiveEvents
        self.lastFix = lastFix
        self.lastSegmentIndex = lastSegmentIndex
    }

    /// A snapshot found on launch whose navigation state is not terminal needs recovery.
    public var needsRecovery: Bool { !navigationState.isTerminal }
}

public protocol ActiveRideStore: Sendable {
    func save(_ state: ActiveRideState) throws
    func load() throws -> ActiveRideState?
    func clear() throws
}

/// Stores the active ride as `active-ride.json` under `directory`, written atomically.
public struct FileActiveRideStore: ActiveRideStore {
    public static let fileName = "active-ride.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public func save(_ state: ActiveRideState) throws {
        try FileStorage.ensureDirectory(directory)
        let data = try JSONCoding.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    public func load() throws -> ActiveRideState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONCoding.decode(ActiveRideState.self, from: data)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
