import Foundation

/// Generic cursor-paginated list: `{"items": [...], "nextCursor": "..."}`.
public struct Page<Item: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var items: [Item]
    public var nextCursor: String?

    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    public var hasMore: Bool { nextCursor != nil }
}

public struct APIErrorBody: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var details: [String: JSONValue]?

    public init(code: String, message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct APIErrorEnvelope: Codable, Hashable, Sendable {
    public var error: APIErrorBody

    public init(error: APIErrorBody) {
        self.error = error
    }
}

/// Stable error codes from docs/API.md.
public enum APIErrorCode {
    public static let validationError = "VALIDATION_ERROR"
    public static let unauthenticated = "UNAUTHENTICATED"
    public static let forbidden = "FORBIDDEN"
    public static let notFound = "NOT_FOUND"
    public static let conflict = "CONFLICT"
    public static let questInvalidTransition = "QUEST_INVALID_TRANSITION"
    public static let rideInvalidState = "RIDE_INVALID_STATE"
    public static let rideDuplicate = "RIDE_DUPLICATE"
    public static let routeGenerationFailed = "ROUTE_GENERATION_FAILED"
    public static let questGenerationFailed = "QUEST_GENERATION_FAILED"
    public static let featureDisabled = "FEATURE_DISABLED"
    public static let rateLimited = "RATE_LIMITED"
}

public struct StravaStatus: Codable, Hashable, Sendable {
    public var connected: Bool
    public var athleteName: String?
    public var uploadMode: StravaUploadMode
    public var enabled: Bool?

    public init(connected: Bool, athleteName: String? = nil, uploadMode: StravaUploadMode = .never, enabled: Bool? = nil) {
        self.connected = connected
        self.athleteName = athleteName
        self.uploadMode = uploadMode
        self.enabled = enabled
    }
}

public struct StravaAuthorizeResponse: Codable, Hashable, Sendable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

public struct StravaCallbackRequest: Codable, Hashable, Sendable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

/// `{"status": "QUEUED"}` style acknowledgements.
public struct ProcessingStatus: Codable, Hashable, Sendable {
    public var status: String

    public init(status: String) {
        self.status = status
    }
}

/// `PUT /devices`.
public struct DeviceRegistration: Codable, Hashable, Sendable {
    public var token: String
    public var platform: DevicePlatform
    public var environment: APNSEnvironment

    public init(token: String, platform: DevicePlatform, environment: APNSEnvironment = .production) {
        self.token = token
        self.platform = platform
        self.environment = environment
    }
}

public struct LevelLimits: Codable, Hashable, Sendable {
    public var max: Int
    public var maxClass: Int?

    public init(max: Int, maxClass: Int? = nil) {
        self.max = max
        self.maxClass = maxClass
    }
}

/// `GET /config`.
public struct AppConfig: Codable, Hashable, Sendable {
    public var featureFlags: [String: Bool]
    public var h3Resolution: Int
    public var levels: LevelLimits
    public var environment: String?

    public init(featureFlags: [String: Bool], h3Resolution: Int, levels: LevelLimits, environment: String? = nil) {
        self.featureFlags = featureFlags
        self.h3Resolution = h3Resolution
        self.levels = levels
        self.environment = environment
    }

    public func isEnabled(_ flag: String) -> Bool { featureFlags[flag] ?? false }
}

/// Well-known feature flag names.
public enum FeatureFlag {
    public static let wizardClass = "wizard_class"
    public static let warriorClass = "warrior_class"
    public static let scribeClass = "scribe_class"
    public static let partyQuests = "party_quests"
    public static let fogOfWar = "fog_of_war"
    public static let storyQuests = "story_quests"
    public static let strava = "strava"
}

/// `GET /health`.
public struct HealthStatus: Codable, Hashable, Sendable {
    public var status: String
    public var version: String

    public init(status: String, version: String) {
        self.status = status
        self.version = version
    }
}
