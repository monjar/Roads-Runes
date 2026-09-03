import Foundation

public struct UserSettings: Codable, Hashable, Sendable {
    public var defaultRideVisibility: Visibility
    public var batteryMode: BatteryMode
    public var mapStyle: MapStyle
    public var stravaUploadMode: StravaUploadMode
    public var units: Units

    public init(
        defaultRideVisibility: Visibility = .privateOnly,
        batteryMode: BatteryMode = .balanced,
        mapStyle: MapStyle = .adventure,
        stravaUploadMode: StravaUploadMode = .never,
        units: Units = .metric
    ) {
        self.defaultRideVisibility = defaultRideVisibility
        self.batteryMode = batteryMode
        self.mapStyle = mapStyle
        self.stravaUploadMode = stravaUploadMode
        self.units = units
    }
}

public struct User: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var avatarUrl: String?
    public var createdAt: Date
    public var hasCharacter: Bool
    public var settings: UserSettings

    public init(id: UUID, displayName: String, avatarUrl: String? = nil, createdAt: Date, hasCharacter: Bool, settings: UserSettings) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.createdAt = createdAt
        self.hasCharacter = hasCharacter
        self.settings = settings
    }
}

/// `PATCH /users/me`. Only non-nil fields are sent.
public struct UserUpdate: Codable, Hashable, Sendable {
    public var displayName: String?
    public var avatarUrl: String?
    public var settings: UserSettings?

    public init(displayName: String? = nil, avatarUrl: String? = nil, settings: UserSettings? = nil) {
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, avatarUrl, settings
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try container.encodeIfPresent(settings, forKey: .settings)
    }
}

public struct AdventureSummaryPublic: Codable, Hashable, Sendable {
    public var rideId: UUID
    public var questTitle: String?
    public var completedAt: Date
    public var distanceMeters: Double
    public var newTerritoryMeters: Double
    public var xpAwarded: Int

    public init(rideId: UUID, questTitle: String? = nil, completedAt: Date, distanceMeters: Double, newTerritoryMeters: Double, xpAwarded: Int) {
        self.rideId = rideId
        self.questTitle = questTitle
        self.completedAt = completedAt
        self.distanceMeters = distanceMeters
        self.newTerritoryMeters = newTerritoryMeters
        self.xpAwarded = xpAwarded
    }
}

/// `GET /users/{id}`. Never contains home location or live position.
public struct PublicProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var avatarUrl: String?
    public var characterClass: CharacterClass?
    public var overallLevel: Int?
    public var title: String?
    public var questsCompleted: Int
    public var discoveriesFound: Int
    public var favouriteTerrain: String?
    public var friendship: FriendshipState
    public var recentAdventures: [AdventureSummaryPublic]

    public init(
        id: UUID, displayName: String, avatarUrl: String? = nil, characterClass: CharacterClass? = nil,
        overallLevel: Int? = nil, title: String? = nil, questsCompleted: Int, discoveriesFound: Int,
        favouriteTerrain: String? = nil, friendship: FriendshipState, recentAdventures: [AdventureSummaryPublic]
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.characterClass = characterClass
        self.overallLevel = overallLevel
        self.title = title
        self.questsCompleted = questsCompleted
        self.discoveriesFound = discoveriesFound
        self.favouriteTerrain = favouriteTerrain
        self.friendship = friendship
        self.recentAdventures = recentAdventures
    }
}
