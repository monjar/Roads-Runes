import Foundation

/// One method per endpoint in docs/API.md. Implemented by `APIClient`
/// (network) and `MockAPI` (in-memory, for previews and tests).
public protocol RoadsAndRunesAPI: Sendable {
    // MARK: Auth
    func signInWithApple(_ request: AppleSignInRequest) async throws -> TokenResponse
    func refresh(_ request: RefreshRequest) async throws -> TokenResponse
    func devSignIn(_ request: DevSignInRequest) async throws -> TokenResponse
    func logout() async throws

    // MARK: Users
    func me() async throws -> User
    func updateMe(_ update: UserUpdate) async throws -> User
    func profile(userId: UUID) async throws -> PublicProfile

    // MARK: Character
    func classes() async throws -> [ClassInfo]
    func createCharacter(_ request: CharacterCreate) async throws -> Character
    func character() async throws -> Character
    func changeClass(_ request: CharacterClassChange) async throws -> Character
    func resetCharacter() async throws
    func wallet() async throws -> Wallet
    func walletTransactions(limit: Int?, cursor: String?) async throws -> Page<WalletTransaction>
    func worldObjects(near center: Coordinate, radiusMeters: Double) async throws -> [WorldObject]
    func worldObject(id: UUID) async throws -> WorldObject
    /// Today's bounty; nil until the world has been looked at today, or once it is gone.
    func bounty() async throws -> WorldObject?
    func lure(at center: Coordinate) async throws -> [WorldObject]
    func abilities() async throws -> [AbilityState]
    func unlockAbility(id: String) async throws -> Character
    func bikes() async throws -> [Bike]
    func createBike(_ bike: BikeIn) async throws -> Bike
    func updateBike(id: UUID, _ patch: BikeIn) async throws -> Bike
    func deleteBike(id: UUID) async throws
    func riderProfile() async throws -> RiderProfile
    func updateRiderProfile(_ profile: RiderProfile) async throws -> RiderProfile

    // MARK: World
    func world(center: Coordinate, radiusMeters: Double) async throws -> WorldSnapshot
    func exploration(in box: BoundingBox) async throws -> ExplorationResponse
    func explorationStats() async throws -> ExplorationStats

    // MARK: Quests
    func quests(near: Coordinate, status: QuestStatus?, limit: Int?, cursor: String?) async throws -> Page<Quest>
    func generateQuests(_ request: QuestGenerateRequest) async throws -> Page<Quest>
    func quest(id: UUID) async throws -> Quest
    func acceptQuest(id: UUID) async throws -> Quest
    func startQuest(id: UUID, rideId: UUID?) async throws -> Quest
    func reportQuestProgress(id: UUID, events: [ObjectiveEvent]) async throws -> Quest
    func completeQuest(id: UUID, rideId: UUID?) async throws -> QuestCompletion
    func abandonQuest(id: UUID) async throws -> Quest

    // MARK: Routes
    func generateRoutes(_ request: RouteGenerateRequest) async throws -> RouteGenerateResponse
    func route(id: UUID) async throws -> RouteOption
    func routePackage(id: UUID) async throws -> RoutePackage
    /// The quest's fixed route: created on first request, then stable until the rider tweaks it.
    func questRoute(id: UUID) async throws -> RouteOption

    // MARK: Rides
    func createRide(_ request: RideCreate) async throws -> Ride
    func rides(limit: Int?, cursor: String?) async throws -> Page<Ride>
    func ride(id: UUID) async throws -> Ride
    func uploadRidePoints(id: UUID, _ batch: RidePointsBatch) async throws -> Ride
    func uploadRideExploration(id: UUID, _ batch: RideCellsBatch) async throws -> Ride
    func completeRide(id: UUID, _ completion: RideComplete) async throws -> RideCompleteResponse
    /// `nil` while the server is still processing (HTTP 202).
    func rideSummary(id: UUID) async throws -> AdventureSummary?
    func rideGeometry(id: UUID) async throws -> RideGeometry
    func updateRide(id: UUID, _ patch: RidePatch) async throws -> Ride
    func deleteRide(id: UUID) async throws
    /// URL of the GPX/TCX export; the caller attaches the bearer token when downloading.
    func rideExportURL(id: UUID, format: RideExportFormat) -> URL

    // MARK: Journal
    func adventures(limit: Int?, cursor: String?) async throws -> Page<AdventureEntry>
    func journalStats() async throws -> ExplorationStats

    // MARK: Discoveries
    func discoveries(near: Coordinate, radiusMeters: Double, category: DiscoveryCategory?, limit: Int?, cursor: String?) async throws -> Page<DiscoverySummary>
    func discovery(id: UUID) async throws -> Discovery
    func myDiscoveries(limit: Int?, cursor: String?) async throws -> Page<UserDiscovery>
    func updateUserDiscovery(id: UUID, _ update: UserDiscoveryIn) async throws -> UserDiscovery
    func createDiscovery(_ request: DiscoveryCreate) async throws -> Discovery

    // MARK: Friends & feed
    func friends() async throws -> [FriendSummary]
    func friendRequests() async throws -> FriendRequests
    func sendFriendRequest(userId: UUID) async throws -> FriendRequestResult
    func acceptFriendRequest(id: UUID) async throws -> FriendRequests
    func declineFriendRequest(id: UUID) async throws -> FriendRequests
    func removeFriend(userId: UUID) async throws
    func blockUser(userId: UUID) async throws
    func feed(limit: Int?, cursor: String?) async throws -> Page<FeedEvent>

    // MARK: Parties
    func createParty(_ request: PartyCreate) async throws -> Party
    func parties() async throws -> [Party]
    func party(id: UUID) async throws -> Party
    func inviteToParty(id: UUID, userId: UUID) async throws -> Party
    func acceptPartyInvite(id: UUID) async throws -> Party
    func leaveParty(id: UUID) async throws -> Party
    func readyParty(id: UUID) async throws -> Party
    func startParty(id: UUID) async throws -> Party
    func cancelParty(id: UUID) async throws -> Party

    // MARK: Integrations
    func stravaStatus() async throws -> StravaStatus
    func stravaAuthorize() async throws -> StravaAuthorizeResponse
    func stravaCallback(code: String) async throws -> StravaStatus
    func disconnectStrava() async throws
    func uploadRideToStrava(rideId: UUID) async throws -> ProcessingStatus

    // MARK: Devices & meta
    func registerDevice(_ registration: DeviceRegistration) async throws
    func unregisterDevice(token: String) async throws
    func config() async throws -> AppConfig
    func health() async throws -> HealthStatus
}

/// Convenience overloads with default pagination arguments.
extension RoadsAndRunesAPI {
    public func quests(near: Coordinate, status: QuestStatus? = .available) async throws -> Page<Quest> {
        try await quests(near: near, status: status, limit: nil, cursor: nil)
    }

    public func rides() async throws -> Page<Ride> {
        try await rides(limit: nil, cursor: nil)
    }

    public func adventures() async throws -> Page<AdventureEntry> {
        try await adventures(limit: nil, cursor: nil)
    }

    public func feed() async throws -> Page<FeedEvent> {
        try await feed(limit: nil, cursor: nil)
    }

    public func myDiscoveries() async throws -> Page<UserDiscovery> {
        try await myDiscoveries(limit: nil, cursor: nil)
    }

    public func discoveries(near: Coordinate, radiusMeters: Double = 5000, category: DiscoveryCategory? = nil) async throws -> Page<DiscoverySummary> {
        try await discoveries(near: near, radiusMeters: radiusMeters, category: category, limit: nil, cursor: nil)
    }
}
