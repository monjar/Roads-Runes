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
    /// The world's pages and what this player has met (`codex` flag).
    func codex() async throws -> Codex
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
    /// Whether a lamp at this spot would bring something, and where, without spending anything.
    func lampCheck(at center: Coordinate) async throws -> LampCheck
    /// Open a chest or pick up a piece from beside it. Throws `OBJECT_OUT_OF_RANGE` when it is not within reach.
    func claimWorldObject(id: UUID, _ request: WorldObjectClaimRequest) async throws -> WorldObjectClaim
    func abilities() async throws -> [AbilityState]
    func unlockAbility(id: String) async throws -> Character
    /// Every title there is, earned first (0.6.2).
    func titles() async throws -> [TitleInfo]
    /// Wear an earned title, or nil to wear the newest earned again (0.6.2).
    func wearTitle(slug: String?) async throws -> Character
    func bikes() async throws -> [Bike]
    func createBike(_ bike: BikeIn) async throws -> Bike
    func updateBike(id: UUID, _ patch: BikeIn) async throws -> Bike
    func deleteBike(id: UUID) async throws
    func riderProfile() async throws -> RiderProfile
    func updateRiderProfile(_ profile: RiderProfile) async throws -> RiderProfile

    // MARK: What you carry (0.7.2)
    /// The slots, the bag and the consumables. The first call after 0.7.2 pays every
    /// level already reached and says so in `levelRewardsPaid`, once.
    func inventory() async throws -> InventoryState
    /// Wear an item in its slot, or take the slot's item off (`itemId` nil).
    func wearGear(_ choice: GearChoice) async throws -> InventoryState
    func sellItem(id: UUID) async throws -> SellResult
    /// Use a map piece or open a sealed chest (a lamp is used by `lure`, a rest token by itself).
    func useConsumable(id: String, _ request: ConsumableUseRequest) async throws -> ConsumableUseResult
    /// This week's four offers, or when the stall opens.
    func stall() async throws -> Stall
    func buyOffer(id: String) async throws -> InventoryState
    /// What each of the fifty levels gives, and which are reached.
    func levelRewards() async throws -> [LevelStep]

    // MARK: Between rides (0.7.3)
    /// Today's pledge and tomorrow's; `today` is the phone's own date, "YYYY-MM-DD".
    func pledges(today: String) async throws -> PledgeState
    /// Pledge a live creature or a quest on the board for a day; one a day, a second replaces it.
    func pledge(_ request: PledgeRequest) async throws -> Pledge
    func cancelPledge(day: String) async throws
    /// Your letters, newest first.
    func letters() async throws -> [Letter]
    func writeLetter(_ request: LetterCreate) async throws -> Letter
    func deleteLetter(id: UUID) async throws
    /// A sealed quest of 20, 40 or 90 minutes from here, accepted, with its route.
    func sealedQuest(_ request: SealedQuestRequest) async throws -> Quest

    // MARK: World
    func world(center: Coordinate, radiusMeters: Double) async throws -> WorldSnapshot
    func exploration(in box: BoundingBox) async throws -> ExplorationResponse
    func explorationStats() async throws -> ExplorationStats

    // MARK: Quests
    func quests(near: Coordinate, status: QuestStatus?, limit: Int?, cursor: String?) async throws -> Page<Quest>
    func generateQuests(_ request: QuestGenerateRequest) async throws -> Page<Quest>
    func quest(id: UUID) async throws -> Quest
    /// The authored arcs and where this rider stands in each.
    func storyArcs() async throws -> [StoryArc]
    /// This week's notice and how far along it is (0.6.2).
    func weekNotice() async throws -> WeekNotice
    /// Runes held, ranked and inscribed (0.7.0).
    func runes() async throws -> RunesState
    func raiseRune(id: String) async throws -> RunesState
    func inscribe(runes: [String]) async throws -> RunesState
    func runeCuts() async throws -> [RuneCutInfo]
    func deeds() async throws -> DeedsState
    /// A route in a rune's road form, from here (0.7.0).
    func runeRide(_ request: RuneRideRequest) async throws -> RuneRideResponse
    func acceptQuest(id: UUID) async throws -> Quest
    func startQuest(id: UUID, rideId: UUID?) async throws -> Quest
    func reportQuestProgress(id: UUID, events: [ObjectiveEvent]) async throws -> Quest
    func completeQuest(id: UUID, rideId: UUID?) async throws -> QuestCompletion
    func abandonQuest(id: UUID) async throws -> Quest

    // MARK: Routes
    func generateRoutes(_ request: RouteGenerateRequest) async throws -> RouteGenerateResponse
    func route(id: UUID) async throws -> RouteOption
    func routePackage(id: UUID) async throws -> RoutePackage
    /// The quest's route from where the player is: stable while they stay about there,
    /// drawn again once they have moved. With no origin, whatever route it last had.
    func questRoute(id: UUID, from origin: Coordinate?) async throws -> RouteOption
    /// The rest of a ride from where the rider is, when they have left the route.
    func reroute(routeId: UUID, _ request: RerouteRequest) async throws -> RouteOption

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
    /// People by name, to add as friends.
    func searchUsers(query: String) async throws -> [FriendSummary]
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

    public func questRoute(id: UUID) async throws -> RouteOption {
        try await questRoute(id: id, from: nil)
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
