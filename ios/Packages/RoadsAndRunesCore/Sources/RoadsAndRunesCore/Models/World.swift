import Foundation

public struct ExplorationCell: Codable, Hashable, Identifiable, Sendable {
    public var h3: String
    public var state: CellState
    public var firstVisitedAt: Date?

    public var id: String { h3 }

    public init(h3: String, state: CellState, firstVisitedAt: Date? = nil) {
        self.h3 = h3
        self.state = state
        self.firstVisitedAt = firstVisitedAt
    }
}

public struct QuestMarker: Codable, Hashable, Identifiable, Sendable {
    public var questId: UUID
    public var title: String
    public var latitude: Double
    public var longitude: Double
    public var difficulty: Difficulty
    public var questType: String
    public var status: QuestStatus?

    public var id: UUID { questId }
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(questId: UUID, title: String, latitude: Double, longitude: Double, difficulty: Difficulty, questType: String, status: QuestStatus? = nil) {
        self.questId = questId
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.difficulty = difficulty
        self.questType = questType
        self.status = status
    }
}

/// `GET /world` (`WorldOut` on the server).
public struct WorldSnapshot: Codable, Hashable, Sendable {
    public var center: Coordinate
    public var h3Resolution: Int
    public var cells: [ExplorationCell]
    public var discoveries: [DiscoverySummary]
    public var questMarkers: [QuestMarker]
    public var featureFlags: [String: Bool]

    public init(center: Coordinate, h3Resolution: Int, cells: [ExplorationCell], discoveries: [DiscoverySummary], questMarkers: [QuestMarker], featureFlags: [String: Bool]) {
        self.center = center
        self.h3Resolution = h3Resolution
        self.cells = cells
        self.discoveries = discoveries
        self.questMarkers = questMarkers
        self.featureFlags = featureFlags
    }

    public func isEnabled(_ flag: String) -> Bool { featureFlags[flag] ?? false }
}

/// `GET /world/exploration`.
public struct ExplorationResponse: Codable, Hashable, Sendable {
    public var h3Resolution: Int
    public var cells: [ExplorationCell]

    public init(h3Resolution: Int, cells: [ExplorationCell]) {
        self.h3Resolution = h3Resolution
        self.cells = cells
    }
}

/// `GET /world/exploration/stats` and `GET /journal/stats`.
public struct ExplorationStats: Codable, Hashable, Sendable {
    public var cellsVisited: Int
    public var cellsExplored: Int
    public var cellsDiscovered: Int?
    public var newTerritoryKm: Double
    public var uniqueRoadsKm: Double
    public var regionsVisited: Int
    public var questsCompleted: Int
    public var discoveriesFound: Int
    public var storyQuestsCompleted: Int
    public var totalDistanceMeters: Double
    public var totalElevationMeters: Double
    public var ridesCompleted: Int?
    public var averageSpeedMps: Double?
    public var maxSpeedMps: Double?

    public init(
        cellsVisited: Int, cellsExplored: Int, cellsDiscovered: Int? = nil, newTerritoryKm: Double, uniqueRoadsKm: Double,
        regionsVisited: Int, questsCompleted: Int, discoveriesFound: Int, storyQuestsCompleted: Int,
        totalDistanceMeters: Double, totalElevationMeters: Double, ridesCompleted: Int? = nil,
        averageSpeedMps: Double? = nil, maxSpeedMps: Double? = nil
    ) {
        self.cellsVisited = cellsVisited
        self.cellsExplored = cellsExplored
        self.cellsDiscovered = cellsDiscovered
        self.newTerritoryKm = newTerritoryKm
        self.uniqueRoadsKm = uniqueRoadsKm
        self.regionsVisited = regionsVisited
        self.questsCompleted = questsCompleted
        self.discoveriesFound = discoveriesFound
        self.storyQuestsCompleted = storyQuestsCompleted
        self.totalDistanceMeters = totalDistanceMeters
        self.totalElevationMeters = totalElevationMeters
        self.ridesCompleted = ridesCompleted
        self.averageSpeedMps = averageSpeedMps
        self.maxSpeedMps = maxSpeedMps
    }
}
