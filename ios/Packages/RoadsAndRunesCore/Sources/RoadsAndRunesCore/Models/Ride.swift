import Foundation

public struct Ride: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var clientRideId: UUID
    public var status: RideStatus
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var distanceMeters: Double
    public var durationSeconds: Int
    public var movingSeconds: Int
    public var elevationGainMeters: Double
    public var activeCalories: Double?
    public var averageSpeedMps: Double?
    public var maxSpeedMps: Double?
    public var questId: UUID?
    public var bikeId: UUID?
    public var routeId: UUID?
    public var visibility: Visibility
    public var healthKitWorkoutId: String?
    public var pointCount: Int
    public var flags: [String]?
    public var createdAt: Date
    /// How it was done; nil from a server that predates activities (a ride).
    public var activity: Activity?

    public init(
        id: UUID, clientRideId: UUID, status: RideStatus, title: String? = nil, startedAt: Date, endedAt: Date? = nil,
        distanceMeters: Double, durationSeconds: Int, movingSeconds: Int, elevationGainMeters: Double,
        activeCalories: Double? = nil, averageSpeedMps: Double? = nil, maxSpeedMps: Double? = nil, questId: UUID? = nil,
        bikeId: UUID? = nil, routeId: UUID? = nil, visibility: Visibility, healthKitWorkoutId: String? = nil,
        pointCount: Int, flags: [String]? = nil, createdAt: Date, activity: Activity? = nil
    ) {
        self.activity = activity
        self.id = id
        self.clientRideId = clientRideId
        self.status = status
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.movingSeconds = movingSeconds
        self.elevationGainMeters = elevationGainMeters
        self.activeCalories = activeCalories
        self.averageSpeedMps = averageSpeedMps
        self.maxSpeedMps = maxSpeedMps
        self.questId = questId
        self.bikeId = bikeId
        self.routeId = routeId
        self.visibility = visibility
        self.healthKitWorkoutId = healthKitWorkoutId
        self.pointCount = pointCount
        self.flags = flags
        self.createdAt = createdAt
    }
}

/// Upload shape for a GPS sample (`POST /rides/{id}/points`).
public struct RidePoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    public var altitudeMeters: Double?
    public var horizontalAccuracyMeters: Double?
    public var speedMps: Double?
    public var heartRateBpm: Int?

    public init(latitude: Double, longitude: Double, timestamp: Date, altitudeMeters: Double? = nil, horizontalAccuracyMeters: Double? = nil, speedMps: Double? = nil, heartRateBpm: Int? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitudeMeters = altitudeMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMps = speedMps
        self.heartRateBpm = heartRateBpm
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

public struct RideCreate: Codable, Hashable, Sendable {
    public var clientRideId: UUID
    public var startedAt: Date
    public var questId: UUID?
    public var bikeId: UUID?
    public var routeId: UUID?
    /// Names a custom adventure (a ride without a quest); quest rides take the quest title.
    public var title: String?
    /// Ride, run or walk; nil lets the server assume a ride.
    public var activity: Activity?

    public init(clientRideId: UUID, startedAt: Date, questId: UUID? = nil, bikeId: UUID? = nil, routeId: UUID? = nil, title: String? = nil, activity: Activity? = nil) {
        self.clientRideId = clientRideId
        self.startedAt = startedAt
        self.questId = questId
        self.bikeId = bikeId
        self.routeId = routeId
        self.title = title
        self.activity = activity
    }
}

public struct RidePointsBatch: Codable, Hashable, Sendable {
    public var points: [RidePoint]

    public init(points: [RidePoint]) {
        self.points = points
    }
}

public struct RideCellsBatch: Codable, Hashable, Sendable {
    public var cellsVisited: [String]

    public init(cellsVisited: [String]) {
        self.cellsVisited = cellsVisited
    }
}

public struct RideComplete: Codable, Hashable, Sendable {
    public var endedAt: Date
    public var distanceMeters: Double
    public var durationSeconds: Int
    public var movingSeconds: Int?
    public var elevationGainMeters: Double
    public var activeCalories: Double?
    public var points: [RidePoint]
    public var cellsVisited: [String]
    public var objectiveEvents: [ObjectiveEvent]
    public var healthKitWorkoutId: String?
    /// What the phone thinks it beat or opened on the way; optional so queued completions from before decode.
    public var encounterEvents: [EncounterEvent]?

    public init(endedAt: Date, distanceMeters: Double, durationSeconds: Int, movingSeconds: Int? = nil, elevationGainMeters: Double = 0, activeCalories: Double? = nil, points: [RidePoint] = [], cellsVisited: [String] = [], objectiveEvents: [ObjectiveEvent] = [], healthKitWorkoutId: String? = nil, encounterEvents: [EncounterEvent]? = nil) {
        self.encounterEvents = encounterEvents
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.movingSeconds = movingSeconds
        self.elevationGainMeters = elevationGainMeters
        self.activeCalories = activeCalories
        self.points = points
        self.cellsVisited = cellsVisited
        self.objectiveEvents = objectiveEvents
        self.healthKitWorkoutId = healthKitWorkoutId
    }
}

public struct RideCompleteResponse: Codable, Hashable, Sendable {
    public var ride: Ride
    /// `QUEUED` while post-processing is pending, `DONE` once finished.
    public var processing: String

    public init(ride: Ride, processing: String) {
        self.ride = ride
        self.processing = processing
    }
}

public struct RidePatch: Codable, Hashable, Sendable {
    public var visibility: Visibility?
    public var title: String?
    public var notes: String?

    public init(visibility: Visibility? = nil, title: String? = nil, notes: String? = nil) {
        self.visibility = visibility
        self.title = title
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case visibility, title, notes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(visibility, forKey: .visibility)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

public struct RideGeometry: Codable, Hashable, Sendable {
    public var coordinates: [[Double]]
    public var encodedPolyline: String

    public init(coordinates: [[Double]], encodedPolyline: String) {
        self.coordinates = coordinates
        self.encodedPolyline = encodedPolyline
    }

    public var path: [Coordinate] { coordinates.compactMap { Coordinate(geoJSON: $0) } }
}

/// `GET /rides/{id}/summary` once processing has finished.
public struct AdventureSummary: Codable, Hashable, Sendable {
    public var ride: Ride
    public var quest: Quest?
    public var questCompletion: QuestCompletion?
    public var xpAwarded: Int
    public var xpBreakdown: [XPBreakdownEntry]
    public var newCells: Int
    public var newTerritoryMeters: Double
    public var newRoadsMeters: Double
    public var discoveries: [DiscoverySummary]
    public var levelUps: [LevelUp]
    public var abilitiesUnlocked: [Ability]
    public var titlesUnlocked: [String]?
    public var flags: [String]
    /// Active Coins the ride earned, and the purse after; nil from an older server.
    public var acAwarded: Int?
    public var acBreakdown: [ACBreakdownEntry]?
    public var walletBalance: Int?
    /// What the ride took from the world, and what it walked past.
    public var worldObjects: WorldObjectOutcome?

    public init(ride: Ride, quest: Quest? = nil, questCompletion: QuestCompletion? = nil, xpAwarded: Int, xpBreakdown: [XPBreakdownEntry], newCells: Int, newTerritoryMeters: Double, newRoadsMeters: Double, discoveries: [DiscoverySummary], levelUps: [LevelUp], abilitiesUnlocked: [Ability], titlesUnlocked: [String]? = nil, flags: [String], acAwarded: Int? = nil, acBreakdown: [ACBreakdownEntry]? = nil, walletBalance: Int? = nil, worldObjects: WorldObjectOutcome? = nil) {
        self.worldObjects = worldObjects
        self.ride = ride
        self.quest = quest
        self.questCompletion = questCompletion
        self.xpAwarded = xpAwarded
        self.xpBreakdown = xpBreakdown
        self.newCells = newCells
        self.newTerritoryMeters = newTerritoryMeters
        self.newRoadsMeters = newRoadsMeters
        self.discoveries = discoveries
        self.levelUps = levelUps
        self.abilitiesUnlocked = abilitiesUnlocked
        self.titlesUnlocked = titlesUnlocked
        self.flags = flags
        self.acAwarded = acAwarded
        self.acBreakdown = acBreakdown
        self.walletBalance = walletBalance
    }
}

/// `GET /journal/adventures` item.
public struct AdventureEntry: Codable, Hashable, Identifiable, Sendable {
    public var ride: Ride
    public var quest: Quest?
    public var xpAwarded: Int
    public var discoveries: [DiscoverySummary]
    public var newTerritoryMeters: Double
    public var newCells: Int?
    public var levelUps: [LevelUp]?
    public var notes: String?
    public var photos: [String]

    public var id: UUID { ride.id }

    public init(ride: Ride, quest: Quest? = nil, xpAwarded: Int, discoveries: [DiscoverySummary], newTerritoryMeters: Double, newCells: Int? = nil, levelUps: [LevelUp]? = nil, notes: String? = nil, photos: [String] = []) {
        self.ride = ride
        self.quest = quest
        self.xpAwarded = xpAwarded
        self.discoveries = discoveries
        self.newTerritoryMeters = newTerritoryMeters
        self.newCells = newCells
        self.levelUps = levelUps
        self.notes = notes
        self.photos = photos
    }
}

public enum RideExportFormat: String, Sendable {
    case gpx
    case tcx
}
