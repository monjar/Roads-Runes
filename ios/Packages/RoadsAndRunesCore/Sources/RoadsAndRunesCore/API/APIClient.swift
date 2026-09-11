import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIError: Error, CustomStringConvertible {
    /// Non-2xx response carrying the API error envelope.
    case server(code: String, message: String, status: Int)
    case network(Error)
    case decoding(Error)
    /// No credentials, or refresh failed.
    case unauthenticated
    /// HTTP 202: the resource is still being processed.
    case processing
    case invalidURL

    public var description: String {
        switch self {
        case .server(let code, let message, let status): return "\(status) \(code): \(message)"
        case .network(let error): return "Network error: \(error)"
        case .decoding(let error): return "Decoding error: \(error)"
        case .unauthenticated: return "Not authenticated"
        case .processing: return "Still processing"
        case .invalidURL: return "Invalid URL"
        }
    }

    public var errorCode: String? {
        if case .server(let code, _, _) = self { return code }
        return nil
    }

    public var isNotFound: Bool { errorCode == APIErrorCode.notFound }
}

extension APIError: LocalizedError {
    /// What a rider reads under a button that failed. Without this, SwiftUI
    /// showed "The operation couldn't be completed. (RoadsAndRunesCore.APIError error 0.)".
    public var errorDescription: String? {
        switch self {
        case .server(_, let message, let status):
            return status >= 500 || message.isEmpty ? "Something went wrong on our side. Try again in a moment." : message
        case .network(let error):
            if (error as? URLError)?.code == .timedOut { return "The server took too long to answer. Try again." }
            return "Can't reach Roads & Runes. Check your connection and try again."
        case .decoding:
            return "The app couldn't read the server's answer. It may need an update."
        case .unauthenticated:
            return "Your session has ended. Sign in again."
        case .processing:
            return "Still working on it. This takes a moment."
        case .invalidURL:
            return "The server address is not valid."
        }
    }
}

/// URLSession-backed implementation of `RoadsAndRunesAPI`.
///
/// - Injects `Authorization: Bearer` from the `TokenStore`.
/// - On 401, refreshes once via `POST /auth/refresh` and retries.
/// - Maps error envelopes to `APIError.server`.
public actor APIClient: RoadsAndRunesAPI {
    public nonisolated let baseURL: URL
    public nonisolated let apiRoot: URL
    private let session: URLSession
    private let tokenStore: TokenStore
    private let decoder: JSONDecoder
    private var refreshTask: Task<AuthTokens, Error>?

    /// - Parameter baseURL: server origin, e.g. `https://api.example.com`. `/api/v1` is appended.
    public init(baseURL: URL, tokenStore: TokenStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiRoot = baseURL.appendingPathComponent("api/v1")
        self.tokenStore = tokenStore
        self.session = session
        self.decoder = JSONCoding.makeDecoder()
    }

    // MARK: Generic requests

    public func request<T: Decodable>(_ endpoint: Endpoint) async throws -> T {
        let (data, status) = try await send(endpoint, allowRefresh: true)
        if status == 202 { throw APIError.processing }
        return try decode(T.self, from: data)
    }

    /// Like `request` but returns `nil` on HTTP 202.
    public func requestOptional<T: Decodable>(_ endpoint: Endpoint) async throws -> T? {
        let (data, status) = try await send(endpoint, allowRefresh: true)
        if status == 202 { return nil }
        return try decode(T.self, from: data)
    }

    public func requestNoContent(_ endpoint: Endpoint) async throws {
        _ = try await send(endpoint, allowRefresh: true)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: Transport

    private func send(_ endpoint: Endpoint, allowRefresh: Bool) async throws -> (Data, Int) {
        var request = try makeRequest(for: endpoint)
        if endpoint.requiresAuth {
            guard let tokens = tokenStore.load() else { throw APIError.unauthenticated }
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await perform(request)
        let status = response.statusCode
        if (200...299).contains(status) {
            return (data, status)
        }
        if status == 401 {
            if endpoint.requiresAuth, allowRefresh, tokenStore.load() != nil {
                _ = try await refreshTokens()
                return try await send(endpoint, allowRefresh: false)
            }
            throw APIError.unauthenticated
        }
        throw serverError(data: data, status: status)
    }

    private func serverError(data: Data, status: Int) -> APIError {
        if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
            return .server(code: envelope.error.code, message: envelope.error.message, status: status)
        }
        let message = String(data: data, encoding: .utf8) ?? ""
        return .server(code: "HTTP_\(status)", message: message, status: status)
    }

    private nonisolated func makeRequest(for endpoint: Endpoint) throws -> URLRequest {
        guard var components = URLComponents(url: apiRoot, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + endpoint.path
        if !endpoint.query.isEmpty {
            components.queryItems = endpoint.query.map { URLQueryItem(name: $0.name, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = endpoint.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = self.session
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: APIError.network(error))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: APIError.network(URLError(.badServerResponse)))
                    return
                }
                continuation.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    // MARK: Token refresh

    /// Refreshes the access token, coalescing concurrent callers onto one request.
    private func refreshTokens() async throws -> AuthTokens {
        if let task = refreshTask {
            return try await task.value
        }
        guard let current = tokenStore.load() else { throw APIError.unauthenticated }
        let task = Task<AuthTokens, Error> { [weak self] in
            guard let self = self else { throw APIError.unauthenticated }
            return try await self.performRefresh(refreshToken: current.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(refreshToken: String) async throws -> AuthTokens {
        let endpoint = try Endpoints.refresh(RefreshRequest(refreshToken: refreshToken))
        do {
            let (data, _) = try await send(endpoint, allowRefresh: false)
            let response = try decode(TokenResponse.self, from: data)
            let tokens = AuthTokens(response: response)
            tokenStore.save(tokens)
            return tokens
        } catch {
            tokenStore.clear()
            throw APIError.unauthenticated
        }
    }

    private func storeTokens(_ response: TokenResponse) {
        tokenStore.save(AuthTokens(response: response))
    }

    // MARK: Auth

    public func signInWithApple(_ request: AppleSignInRequest) async throws -> TokenResponse {
        let response: TokenResponse = try await self.request(try Endpoints.appleSignIn(request))
        storeTokens(response)
        return response
    }

    public func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
        let response: TokenResponse = try await self.request(try Endpoints.refresh(request))
        storeTokens(response)
        return response
    }

    public func devSignIn(_ request: DevSignInRequest) async throws -> TokenResponse {
        let response: TokenResponse = try await self.request(try Endpoints.devSignIn(request))
        storeTokens(response)
        return response
    }

    public func logout() async throws {
        defer { tokenStore.clear() }
        try await requestNoContent(Endpoints.logout())
    }

    // MARK: Users

    public func me() async throws -> User { try await request(Endpoints.me()) }
    public func updateMe(_ update: UserUpdate) async throws -> User { try await request(try Endpoints.updateMe(update)) }
    public func profile(userId: UUID) async throws -> PublicProfile { try await request(Endpoints.profile(userId: userId)) }

    // MARK: Character

    public func classes() async throws -> [ClassInfo] { try await request(Endpoints.classes()) }
    public func createCharacter(_ request: CharacterCreate) async throws -> Character { try await self.request(try Endpoints.createCharacter(request)) }
    public func character() async throws -> Character { try await request(Endpoints.character()) }
    public func abilities() async throws -> [AbilityState] { try await request(Endpoints.abilities()) }
    public func unlockAbility(id: String) async throws -> Character { try await request(Endpoints.unlockAbility(id: id)) }
    public func bikes() async throws -> [Bike] { try await request(Endpoints.bikes()) }
    public func createBike(_ bike: BikeIn) async throws -> Bike { try await request(try Endpoints.createBike(bike)) }
    public func updateBike(id: UUID, _ patch: BikeIn) async throws -> Bike { try await request(try Endpoints.updateBike(id: id, patch)) }
    public func deleteBike(id: UUID) async throws { try await requestNoContent(Endpoints.deleteBike(id: id)) }
    public func riderProfile() async throws -> RiderProfile { try await request(Endpoints.riderProfile()) }
    public func updateRiderProfile(_ profile: RiderProfile) async throws -> RiderProfile { try await request(try Endpoints.updateRiderProfile(profile)) }

    // MARK: World

    public func world(center: Coordinate, radiusMeters: Double) async throws -> WorldSnapshot {
        try await request(Endpoints.world(center: center, radiusMeters: radiusMeters))
    }
    public func exploration(in box: BoundingBox) async throws -> ExplorationResponse { try await request(Endpoints.exploration(in: box)) }
    public func explorationStats() async throws -> ExplorationStats { try await request(Endpoints.explorationStats()) }

    // MARK: Quests

    public func quests(near: Coordinate, status: QuestStatus?, limit: Int?, cursor: String?) async throws -> Page<Quest> {
        try await request(Endpoints.quests(near: near, status: status, limit: limit, cursor: cursor))
    }
    public func generateQuests(_ request: QuestGenerateRequest) async throws -> Page<Quest> { try await self.request(try Endpoints.generateQuests(request)) }
    public func quest(id: UUID) async throws -> Quest { try await request(Endpoints.quest(id: id)) }
    public func acceptQuest(id: UUID) async throws -> Quest { try await request(Endpoints.acceptQuest(id: id)) }
    public func startQuest(id: UUID, rideId: UUID?) async throws -> Quest { try await request(try Endpoints.startQuest(id: id, rideId: rideId)) }
    public func reportQuestProgress(id: UUID, events: [ObjectiveEvent]) async throws -> Quest {
        try await request(try Endpoints.questProgress(id: id, events: events))
    }
    public func completeQuest(id: UUID, rideId: UUID?) async throws -> QuestCompletion { try await request(try Endpoints.completeQuest(id: id, rideId: rideId)) }
    public func abandonQuest(id: UUID) async throws -> Quest { try await request(Endpoints.abandonQuest(id: id)) }

    // MARK: Routes

    public func generateRoutes(_ request: RouteGenerateRequest) async throws -> RouteGenerateResponse { try await self.request(try Endpoints.generateRoutes(request)) }
    public func route(id: UUID) async throws -> RouteOption { try await request(Endpoints.route(id: id)) }
    public func routePackage(id: UUID) async throws -> RoutePackage { try await request(Endpoints.routePackage(id: id)) }
    public func questRoute(id: UUID) async throws -> RouteOption { try await request(Endpoints.questRoute(id: id)) }

    // MARK: Rides

    public func createRide(_ request: RideCreate) async throws -> Ride { try await self.request(try Endpoints.createRide(request)) }
    public func rides(limit: Int?, cursor: String?) async throws -> Page<Ride> { try await request(Endpoints.rides(limit: limit, cursor: cursor)) }
    public func ride(id: UUID) async throws -> Ride { try await request(Endpoints.ride(id: id)) }
    public func uploadRidePoints(id: UUID, _ batch: RidePointsBatch) async throws -> Ride { try await request(try Endpoints.ridePoints(id: id, batch)) }
    public func uploadRideExploration(id: UUID, _ batch: RideCellsBatch) async throws -> Ride { try await request(try Endpoints.rideExploration(id: id, batch)) }
    public func completeRide(id: UUID, _ completion: RideComplete) async throws -> RideCompleteResponse {
        try await request(try Endpoints.completeRide(id: id, completion))
    }
    public func rideSummary(id: UUID) async throws -> AdventureSummary? { try await requestOptional(Endpoints.rideSummary(id: id)) }
    public func rideGeometry(id: UUID) async throws -> RideGeometry { try await request(Endpoints.rideGeometry(id: id)) }
    public func updateRide(id: UUID, _ patch: RidePatch) async throws -> Ride { try await request(try Endpoints.updateRide(id: id, patch)) }
    public func deleteRide(id: UUID) async throws { try await requestNoContent(Endpoints.deleteRide(id: id)) }
    public nonisolated func rideExportURL(id: UUID, format: RideExportFormat) -> URL {
        let endpoint = Endpoints.rideExport(id: id, format: format)
        if let request = try? makeRequest(for: endpoint), let url = request.url {
            return url
        }
        return apiRoot.appendingPathComponent("rides/\(id.uuidString)/export")
    }

    // MARK: Journal

    public func adventures(limit: Int?, cursor: String?) async throws -> Page<AdventureEntry> { try await request(Endpoints.adventures(limit: limit, cursor: cursor)) }
    public func journalStats() async throws -> ExplorationStats { try await request(Endpoints.journalStats()) }

    // MARK: Discoveries

    public func discoveries(near: Coordinate, radiusMeters: Double, category: DiscoveryCategory?, limit: Int?, cursor: String?) async throws -> Page<DiscoverySummary> {
        try await request(Endpoints.discoveries(near: near, radiusMeters: radiusMeters, category: category, limit: limit, cursor: cursor))
    }
    public func discovery(id: UUID) async throws -> Discovery { try await request(Endpoints.discovery(id: id)) }
    public func myDiscoveries(limit: Int?, cursor: String?) async throws -> Page<UserDiscovery> { try await request(Endpoints.myDiscoveries(limit: limit, cursor: cursor)) }
    public func updateUserDiscovery(id: UUID, _ update: UserDiscoveryIn) async throws -> UserDiscovery { try await request(try Endpoints.updateUserDiscovery(id: id, update)) }
    public func createDiscovery(_ request: DiscoveryCreate) async throws -> Discovery { try await self.request(try Endpoints.createDiscovery(request)) }

    // MARK: Friends & feed

    public func friends() async throws -> [FriendSummary] { try await request(Endpoints.friends()) }
    public func friendRequests() async throws -> FriendRequests { try await request(Endpoints.friendRequests()) }
    public func sendFriendRequest(userId: UUID) async throws -> FriendRequestResult { try await request(try Endpoints.sendFriendRequest(userId: userId)) }
    public func acceptFriendRequest(id: UUID) async throws -> FriendRequests { try await request(Endpoints.acceptFriendRequest(id: id)) }
    public func declineFriendRequest(id: UUID) async throws -> FriendRequests { try await request(Endpoints.declineFriendRequest(id: id)) }
    public func removeFriend(userId: UUID) async throws { try await requestNoContent(Endpoints.removeFriend(userId: userId)) }
    public func blockUser(userId: UUID) async throws { try await requestNoContent(Endpoints.blockUser(userId: userId)) }
    public func feed(limit: Int?, cursor: String?) async throws -> Page<FeedEvent> { try await request(Endpoints.feed(limit: limit, cursor: cursor)) }

    // MARK: Parties

    public func createParty(_ request: PartyCreate) async throws -> Party { try await self.request(try Endpoints.createParty(request)) }
    public func parties() async throws -> [Party] { try await request(Endpoints.parties()) }
    public func party(id: UUID) async throws -> Party { try await request(Endpoints.party(id: id)) }
    public func inviteToParty(id: UUID, userId: UUID) async throws -> Party { try await request(try Endpoints.inviteToParty(id: id, userId: userId)) }
    public func acceptPartyInvite(id: UUID) async throws -> Party { try await request(Endpoints.acceptParty(id: id)) }
    public func leaveParty(id: UUID) async throws -> Party { try await request(Endpoints.leaveParty(id: id)) }
    public func readyParty(id: UUID) async throws -> Party { try await request(Endpoints.readyParty(id: id)) }
    public func startParty(id: UUID) async throws -> Party { try await request(Endpoints.startParty(id: id)) }
    public func cancelParty(id: UUID) async throws -> Party { try await request(Endpoints.cancelParty(id: id)) }

    // MARK: Integrations

    public func stravaStatus() async throws -> StravaStatus { try await request(Endpoints.stravaStatus()) }
    public func stravaAuthorize() async throws -> StravaAuthorizeResponse { try await request(Endpoints.stravaAuthorize()) }
    public func stravaCallback(code: String) async throws -> StravaStatus { try await request(try Endpoints.stravaCallback(code: code)) }
    public func disconnectStrava() async throws { try await requestNoContent(Endpoints.stravaDisconnect()) }
    public func uploadRideToStrava(rideId: UUID) async throws -> ProcessingStatus { try await request(Endpoints.stravaUpload(rideId: rideId)) }

    // MARK: Devices & meta

    public func registerDevice(_ registration: DeviceRegistration) async throws { try await requestNoContent(try Endpoints.registerDevice(registration)) }
    public func unregisterDevice(token: String) async throws { try await requestNoContent(Endpoints.unregisterDevice(token: token)) }
    public func config() async throws -> AppConfig { try await request(Endpoints.config()) }
    public func health() async throws -> HealthStatus { try await request(Endpoints.health()) }
}
