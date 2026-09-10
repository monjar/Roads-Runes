import Foundation

public struct DiscoverySummary: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: DiscoveryCategory
    public var latitude: Double
    public var longitude: Double
    public var source: DiscoverySource
    public var discoveredByUser: Bool
    public var discoveredAt: Date?

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(id: UUID, name: String, category: DiscoveryCategory, latitude: Double, longitude: Double, source: DiscoverySource, discoveredByUser: Bool, discoveredAt: Date? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
        self.discoveredByUser = discoveredByUser
        self.discoveredAt = discoveredAt
    }
}

public struct UserDiscovery: Codable, Hashable, Identifiable, Sendable {
    public var discoveryId: UUID
    public var discoveredAt: Date
    public var rideId: UUID?
    public var note: String?
    public var rating: Int?
    public var tags: [String]
    public var photoIds: [String]
    public var visibility: Visibility

    public var id: UUID { discoveryId }

    public init(discoveryId: UUID, discoveredAt: Date, rideId: UUID? = nil, note: String? = nil, rating: Int? = nil, tags: [String] = [], photoIds: [String] = [], visibility: Visibility = .privateOnly) {
        self.discoveryId = discoveryId
        self.discoveredAt = discoveredAt
        self.rideId = rideId
        self.note = note
        self.rating = rating
        self.tags = tags
        self.photoIds = photoIds
        self.visibility = visibility
    }
}

/// `GET /discoveries/{id}`: the summary plus detail fields.
public struct Discovery: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: DiscoveryCategory
    public var latitude: Double
    public var longitude: Double
    public var source: DiscoverySource
    public var discoveredByUser: Bool
    public var discoveredAt: Date?
    public var description: String?
    public var osmId: String?
    public var tags: [String: JSONValue]?
    public var userDiscovery: UserDiscovery?

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public var summary: DiscoverySummary {
        DiscoverySummary(id: id, name: name, category: category, latitude: latitude, longitude: longitude, source: source, discoveredByUser: discoveredByUser, discoveredAt: discoveredAt)
    }

    public init(id: UUID, name: String, category: DiscoveryCategory, latitude: Double, longitude: Double, source: DiscoverySource, discoveredByUser: Bool, discoveredAt: Date? = nil, description: String? = nil, osmId: String? = nil, tags: [String: JSONValue]? = nil, userDiscovery: UserDiscovery? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.source = source
        self.discoveredByUser = discoveredByUser
        self.discoveredAt = discoveredAt
        self.description = description
        self.osmId = osmId
        self.tags = tags
        self.userDiscovery = userDiscovery
    }
}

/// `PUT /discoveries/{id}/user`.
public struct UserDiscoveryIn: Codable, Hashable, Sendable {
    public var note: String?
    public var rating: Int?
    public var tags: [String]
    public var photoIds: [String]
    public var visibility: Visibility?

    public init(note: String? = nil, rating: Int? = nil, tags: [String] = [], photoIds: [String] = [], visibility: Visibility? = nil) {
        self.note = note
        self.rating = rating
        self.tags = tags
        self.photoIds = photoIds
        self.visibility = visibility
    }
}

/// `POST /discoveries` (user-created discovery).
public struct DiscoveryCreate: Codable, Hashable, Sendable {
    public var name: String
    public var category: DiscoveryCategory
    public var latitude: Double
    public var longitude: Double
    public var description: String?

    public init(name: String, category: DiscoveryCategory = .custom, latitude: Double, longitude: Double, description: String? = nil) {
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.description = description
    }
}
