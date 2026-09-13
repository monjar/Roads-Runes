import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

public struct QueryItem: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A single API call, relative to the `/api/v1` base path.
public struct Endpoint: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [QueryItem]
    public var body: Data?
    public var requiresAuth: Bool
    /// Seconds before the call is given up on; nil takes the session's default (60).
    /// Planning a route can mean importing a fresh area and three routing calls on a
    /// server that was asleep, which the default cut off with "took too long".
    public var timeout: TimeInterval?

    public init(method: HTTPMethod, path: String, query: [QueryItem] = [], body: Data? = nil, requiresAuth: Bool = true, timeout: TimeInterval? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.requiresAuth = requiresAuth
        self.timeout = timeout
    }

    /// Convenience for JSON bodies encoded with the shared encoder.
    public static func json<Body: Encodable>(_ method: HTTPMethod, _ path: String, body: Body, query: [QueryItem] = [], requiresAuth: Bool = true, timeout: TimeInterval? = nil) throws -> Endpoint {
        Endpoint(method: method, path: path, query: query, body: try JSONCoding.encode(body), requiresAuth: requiresAuth, timeout: timeout)
    }
}

/// Endpoint builders mirroring docs/API.md. Pure functions; no networking.
public enum Endpoints {
    // MARK: Auth
    public static func appleSignIn(_ request: AppleSignInRequest) throws -> Endpoint {
        try .json(.post, "/auth/apple", body: request, requiresAuth: false)
    }
    public static func refresh(_ request: RefreshRequest) throws -> Endpoint {
        try .json(.post, "/auth/refresh", body: request, requiresAuth: false)
    }
    public static func devSignIn(_ request: DevSignInRequest) throws -> Endpoint {
        try .json(.post, "/auth/dev", body: request, requiresAuth: false)
    }
    public static func logout() -> Endpoint { Endpoint(method: .post, path: "/auth/logout") }

    // MARK: Users
    public static func me() -> Endpoint { Endpoint(method: .get, path: "/users/me") }
    public static func updateMe(_ update: UserUpdate) throws -> Endpoint { try .json(.patch, "/users/me", body: update) }
    public static func profile(userId: UUID) -> Endpoint { Endpoint(method: .get, path: "/users/\(userId.uuidString)") }

    // MARK: Character
    public static func classes() -> Endpoint { Endpoint(method: .get, path: "/character/classes") }
    public static func createCharacter(_ body: CharacterCreate) throws -> Endpoint { try .json(.post, "/character", body: body) }
    public static func character() -> Endpoint { Endpoint(method: .get, path: "/character") }
    public static func abilities() -> Endpoint { Endpoint(method: .get, path: "/character/abilities") }
    public static func unlockAbility(id: String) -> Endpoint { Endpoint(method: .post, path: "/character/abilities/\(id)/unlock") }
    public static func bikes() -> Endpoint { Endpoint(method: .get, path: "/character/bikes") }
    public static func createBike(_ body: BikeIn) throws -> Endpoint { try .json(.post, "/character/bikes", body: body) }
    public static func updateBike(id: UUID, _ body: BikeIn) throws -> Endpoint { try .json(.patch, "/character/bikes/\(id.uuidString)", body: body) }
    public static func deleteBike(id: UUID) -> Endpoint { Endpoint(method: .delete, path: "/character/bikes/\(id.uuidString)") }
    public static func riderProfile() -> Endpoint { Endpoint(method: .get, path: "/character/rider-profile") }
    public static func updateRiderProfile(_ body: RiderProfile) throws -> Endpoint { try .json(.put, "/character/rider-profile", body: body) }

    // MARK: World
    public static func world(center: Coordinate, radiusMeters: Double) -> Endpoint {
        Endpoint(method: .get, path: "/world", query: [
            QueryItem("latitude", format(center.latitude)),
            QueryItem("longitude", format(center.longitude)),
            QueryItem("radiusMeters", format(radiusMeters)),
        ])
    }
    public static func exploration(in box: BoundingBox) -> Endpoint {
        Endpoint(method: .get, path: "/world/exploration", query: [
            QueryItem("minLat", format(box.minLat)), QueryItem("minLon", format(box.minLon)),
            QueryItem("maxLat", format(box.maxLat)), QueryItem("maxLon", format(box.maxLon)),
        ])
    }
    public static func explorationStats() -> Endpoint { Endpoint(method: .get, path: "/world/exploration/stats") }

    // MARK: Quests
    public static func quests(near: Coordinate, status: QuestStatus?, limit: Int?, cursor: String?) -> Endpoint {
        var query = [QueryItem("latitude", format(near.latitude)), QueryItem("longitude", format(near.longitude))]
        if let status = status { query.append(QueryItem("status", status.rawValue)) }
        query.append(contentsOf: pagination(limit: limit, cursor: cursor))
        return Endpoint(method: .get, path: "/quests", query: query)
    }
    public static func generateQuests(_ body: QuestGenerateRequest) throws -> Endpoint { try .json(.post, "/quests/generate", body: body, timeout: 120) }
    public static func quest(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/quests/\(id.uuidString)") }
    public static func acceptQuest(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/quests/\(id.uuidString)/accept") }
    public static func startQuest(id: UUID, rideId: UUID?) throws -> Endpoint {
        try .json(.post, "/quests/\(id.uuidString)/start", body: QuestStartRequest(rideId: rideId))
    }
    public static func questProgress(id: UUID, events: [ObjectiveEvent]) throws -> Endpoint {
        try .json(.post, "/quests/\(id.uuidString)/progress", body: QuestProgressRequest(events: events))
    }
    public static func completeQuest(id: UUID, rideId: UUID?) throws -> Endpoint {
        try .json(.post, "/quests/\(id.uuidString)/complete", body: QuestCompleteRequest(rideId: rideId))
    }
    public static func abandonQuest(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/quests/\(id.uuidString)/abandon") }

    // MARK: Routes
    public static func generateRoutes(_ body: RouteGenerateRequest) throws -> Endpoint { try .json(.post, "/routes/generate", body: body, timeout: 150) }
    public static func route(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/routes/\(id.uuidString)") }
    public static func routePackage(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/routes/\(id.uuidString)/package") }
    public static func questRoute(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/quests/\(id.uuidString)/route") }

    // MARK: Rides
    public static func createRide(_ body: RideCreate) throws -> Endpoint { try .json(.post, "/rides", body: body) }
    public static func rides(limit: Int?, cursor: String?) -> Endpoint {
        Endpoint(method: .get, path: "/rides", query: pagination(limit: limit, cursor: cursor))
    }
    public static func ride(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/rides/\(id.uuidString)") }
    public static func ridePoints(id: UUID, _ body: RidePointsBatch) throws -> Endpoint { try .json(.post, "/rides/\(id.uuidString)/points", body: body) }
    public static func rideExploration(id: UUID, _ body: RideCellsBatch) throws -> Endpoint { try .json(.post, "/rides/\(id.uuidString)/exploration", body: body) }
    public static func completeRide(id: UUID, _ body: RideComplete) throws -> Endpoint { try .json(.post, "/rides/\(id.uuidString)/complete", body: body) }
    public static func rideSummary(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/rides/\(id.uuidString)/summary") }
    public static func rideGeometry(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/rides/\(id.uuidString)/geometry") }
    public static func updateRide(id: UUID, _ body: RidePatch) throws -> Endpoint { try .json(.patch, "/rides/\(id.uuidString)", body: body) }
    public static func deleteRide(id: UUID) -> Endpoint { Endpoint(method: .delete, path: "/rides/\(id.uuidString)") }
    public static func rideExport(id: UUID, format: RideExportFormat) -> Endpoint {
        Endpoint(method: .get, path: "/rides/\(id.uuidString)/export", query: [QueryItem("format", format.rawValue)])
    }

    // MARK: Journal
    public static func adventures(limit: Int?, cursor: String?) -> Endpoint {
        Endpoint(method: .get, path: "/journal/adventures", query: pagination(limit: limit, cursor: cursor))
    }
    public static func journalStats() -> Endpoint { Endpoint(method: .get, path: "/journal/stats") }

    // MARK: Discoveries
    public static func discoveries(near: Coordinate, radiusMeters: Double, category: DiscoveryCategory?, limit: Int?, cursor: String?) -> Endpoint {
        var query = [
            QueryItem("latitude", format(near.latitude)), QueryItem("longitude", format(near.longitude)),
            QueryItem("radiusMeters", format(radiusMeters)),
        ]
        if let category = category { query.append(QueryItem("category", category.rawValue)) }
        query.append(contentsOf: pagination(limit: limit, cursor: cursor))
        return Endpoint(method: .get, path: "/discoveries", query: query)
    }
    public static func discovery(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/discoveries/\(id.uuidString)") }
    public static func myDiscoveries(limit: Int?, cursor: String?) -> Endpoint {
        Endpoint(method: .get, path: "/discoveries/mine", query: pagination(limit: limit, cursor: cursor))
    }
    public static func updateUserDiscovery(id: UUID, _ body: UserDiscoveryIn) throws -> Endpoint {
        try .json(.put, "/discoveries/\(id.uuidString)/user", body: body)
    }
    public static func createDiscovery(_ body: DiscoveryCreate) throws -> Endpoint { try .json(.post, "/discoveries", body: body) }

    // MARK: Social
    public static func friends() -> Endpoint { Endpoint(method: .get, path: "/friends") }
    public static func friendRequests() -> Endpoint { Endpoint(method: .get, path: "/friends/requests") }
    public static func sendFriendRequest(userId: UUID) throws -> Endpoint {
        try .json(.post, "/friends/requests", body: FriendRequestCreate(userId: userId))
    }
    public static func acceptFriendRequest(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/friends/requests/\(id.uuidString)/accept") }
    public static func declineFriendRequest(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/friends/requests/\(id.uuidString)/decline") }
    public static func removeFriend(userId: UUID) -> Endpoint { Endpoint(method: .delete, path: "/friends/\(userId.uuidString)") }
    public static func blockUser(userId: UUID) -> Endpoint { Endpoint(method: .post, path: "/friends/\(userId.uuidString)/block") }
    public static func feed(limit: Int?, cursor: String?) -> Endpoint {
        Endpoint(method: .get, path: "/feed", query: pagination(limit: limit, cursor: cursor))
    }

    // MARK: Parties
    public static func createParty(_ body: PartyCreate) throws -> Endpoint { try .json(.post, "/parties", body: body) }
    public static func parties() -> Endpoint { Endpoint(method: .get, path: "/parties") }
    public static func party(id: UUID) -> Endpoint { Endpoint(method: .get, path: "/parties/\(id.uuidString)") }
    public static func inviteToParty(id: UUID, userId: UUID) throws -> Endpoint {
        try .json(.post, "/parties/\(id.uuidString)/invite", body: PartyInvite(userId: userId))
    }
    public static func acceptParty(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/parties/\(id.uuidString)/accept") }
    public static func leaveParty(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/parties/\(id.uuidString)/leave") }
    public static func readyParty(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/parties/\(id.uuidString)/ready") }
    public static func startParty(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/parties/\(id.uuidString)/start") }
    public static func cancelParty(id: UUID) -> Endpoint { Endpoint(method: .post, path: "/parties/\(id.uuidString)/cancel") }

    // MARK: Integrations
    public static func stravaStatus() -> Endpoint { Endpoint(method: .get, path: "/integrations/strava") }
    public static func stravaAuthorize() -> Endpoint { Endpoint(method: .get, path: "/integrations/strava/authorize") }
    public static func stravaCallback(code: String) throws -> Endpoint {
        try .json(.post, "/integrations/strava/callback", body: StravaCallbackRequest(code: code))
    }
    public static func stravaDisconnect() -> Endpoint { Endpoint(method: .delete, path: "/integrations/strava") }
    public static func stravaUpload(rideId: UUID) -> Endpoint { Endpoint(method: .post, path: "/integrations/strava/upload/\(rideId.uuidString)") }

    // MARK: Devices & meta
    public static func registerDevice(_ body: DeviceRegistration) throws -> Endpoint { try .json(.put, "/devices", body: body) }
    public static func unregisterDevice(token: String) -> Endpoint {
        let escaped = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? token
        return Endpoint(method: .delete, path: "/devices/\(escaped)")
    }
    public static func config() -> Endpoint { Endpoint(method: .get, path: "/config") }
    public static func health() -> Endpoint { Endpoint(method: .get, path: "/health", requiresAuth: false) }

    // MARK: Helpers

    static func pagination(limit: Int?, cursor: String?) -> [QueryItem] {
        var items: [QueryItem] = []
        if let limit = limit { items.append(QueryItem("limit", String(limit))) }
        if let cursor = cursor { items.append(QueryItem("cursor", cursor)) }
        return items
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }
}
