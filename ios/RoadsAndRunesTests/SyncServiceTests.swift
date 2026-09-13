import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// A RoadsAndRunesAPI that fails uploads until told otherwise, to exercise the retry queue.
final class FlakyAPI: RoadsAndRunesAPI, @unchecked Sendable {
    private let inner = MockAPI()
    var failUploads = true
    var uploadedBatches = 0

    func signInWithApple(_ request: AppleSignInRequest) async throws -> TokenResponse { try await inner.signInWithApple(request) }
    func refresh(_ request: RefreshRequest) async throws -> TokenResponse { try await inner.refresh(request) }
    func devSignIn(_ request: DevSignInRequest) async throws -> TokenResponse { try await inner.devSignIn(request) }
    func logout() async throws { try await inner.logout() }
    func me() async throws -> User { try await inner.me() }
    func updateMe(_ update: UserUpdate) async throws -> User { try await inner.updateMe(update) }
    func profile(userId: UUID) async throws -> PublicProfile { try await inner.profile(userId: userId) }
    func classes() async throws -> [ClassInfo] { try await inner.classes() }
    func createCharacter(_ request: CharacterCreate) async throws -> Character { try await inner.createCharacter(request) }
    func character() async throws -> Character { try await inner.character() }
    func changeClass(_ request: CharacterClassChange) async throws -> Character { try await inner.changeClass(request) }
    func resetCharacter() async throws { try await inner.resetCharacter() }
    func wallet() async throws -> Wallet { try await inner.wallet() }
    func walletTransactions(limit: Int?, cursor: String?) async throws -> Page<WalletTransaction> { try await inner.walletTransactions(limit: limit, cursor: cursor) }
    func abilities() async throws -> [AbilityState] { try await inner.abilities() }
    func unlockAbility(id: String) async throws -> Character { try await inner.unlockAbility(id: id) }
    func bikes() async throws -> [Bike] { try await inner.bikes() }
    func createBike(_ bike: BikeIn) async throws -> Bike { try await inner.createBike(bike) }
    func updateBike(id: UUID, _ patch: BikeIn) async throws -> Bike { try await inner.updateBike(id: id, patch) }
    func deleteBike(id: UUID) async throws { try await inner.deleteBike(id: id) }
    func riderProfile() async throws -> RiderProfile { try await inner.riderProfile() }
    func updateRiderProfile(_ profile: RiderProfile) async throws -> RiderProfile { try await inner.updateRiderProfile(profile) }
    func world(center: Coordinate, radiusMeters: Double) async throws -> WorldSnapshot { try await inner.world(center: center, radiusMeters: radiusMeters) }
    func exploration(in box: BoundingBox) async throws -> ExplorationResponse { try await inner.exploration(in: box) }
    func explorationStats() async throws -> ExplorationStats { try await inner.explorationStats() }
    func quests(near: Coordinate, status: QuestStatus?, limit: Int?, cursor: String?) async throws -> Page<Quest> { try await inner.quests(near: near, status: status, limit: limit, cursor: cursor) }
    func generateQuests(_ request: QuestGenerateRequest) async throws -> Page<Quest> { try await inner.generateQuests(request) }
    func quest(id: UUID) async throws -> Quest { try await inner.quest(id: id) }
    func acceptQuest(id: UUID) async throws -> Quest { try await inner.acceptQuest(id: id) }
    func startQuest(id: UUID, rideId: UUID?) async throws -> Quest { try await inner.startQuest(id: id, rideId: rideId) }
    func reportQuestProgress(id: UUID, events: [ObjectiveEvent]) async throws -> Quest { try await inner.reportQuestProgress(id: id, events: events) }
    func completeQuest(id: UUID, rideId: UUID?) async throws -> QuestCompletion { try await inner.completeQuest(id: id, rideId: rideId) }
    func abandonQuest(id: UUID) async throws -> Quest { try await inner.abandonQuest(id: id) }
    func generateRoutes(_ request: RouteGenerateRequest) async throws -> RouteGenerateResponse { try await inner.generateRoutes(request) }
    func route(id: UUID) async throws -> RouteOption { try await inner.route(id: id) }
    func routePackage(id: UUID) async throws -> RoutePackage { try await inner.routePackage(id: id) }
    func questRoute(id: UUID) async throws -> RouteOption { try await inner.questRoute(id: id) }
    func rideExportURL(id: UUID, format: RideExportFormat) -> URL { inner.rideExportURL(id: id, format: format) }
    func createRide(_ request: RideCreate) async throws -> Ride { try await inner.createRide(request) }
    func rides(limit: Int?, cursor: String?) async throws -> Page<Ride> { try await inner.rides(limit: limit, cursor: cursor) }
    func ride(id: UUID) async throws -> Ride { try await inner.ride(id: id) }
    func uploadRidePoints(id: UUID, _ batch: RidePointsBatch) async throws -> Ride {
        if failUploads { throw APIError.network(URLError(.notConnectedToInternet)) }
        uploadedBatches += 1
        return try await inner.uploadRidePoints(id: id, batch)
    }
    func uploadRideExploration(id: UUID, _ batch: RideCellsBatch) async throws -> Ride { try await inner.uploadRideExploration(id: id, batch) }
    func completeRide(id: UUID, _ completion: RideComplete) async throws -> RideCompleteResponse { try await inner.completeRide(id: id, completion) }
    func rideSummary(id: UUID) async throws -> AdventureSummary? { try await inner.rideSummary(id: id) }
    func rideGeometry(id: UUID) async throws -> RideGeometry { try await inner.rideGeometry(id: id) }
    func updateRide(id: UUID, _ patch: RidePatch) async throws -> Ride { try await inner.updateRide(id: id, patch) }
    func deleteRide(id: UUID) async throws { try await inner.deleteRide(id: id) }
    func adventures(limit: Int?, cursor: String?) async throws -> Page<AdventureEntry> { try await inner.adventures(limit: limit, cursor: cursor) }
    func journalStats() async throws -> ExplorationStats { try await inner.journalStats() }
    func discoveries(near: Coordinate, radiusMeters: Double, category: DiscoveryCategory?, limit: Int?, cursor: String?) async throws -> Page<DiscoverySummary> { try await inner.discoveries(near: near, radiusMeters: radiusMeters, category: category, limit: limit, cursor: cursor) }
    func discovery(id: UUID) async throws -> Discovery { try await inner.discovery(id: id) }
    func myDiscoveries(limit: Int?, cursor: String?) async throws -> Page<UserDiscovery> { try await inner.myDiscoveries(limit: limit, cursor: cursor) }
    func updateUserDiscovery(id: UUID, _ update: UserDiscoveryIn) async throws -> UserDiscovery { try await inner.updateUserDiscovery(id: id, update) }
    func createDiscovery(_ request: DiscoveryCreate) async throws -> Discovery { try await inner.createDiscovery(request) }
    func friends() async throws -> [FriendSummary] { try await inner.friends() }
    func friendRequests() async throws -> FriendRequests { try await inner.friendRequests() }
    func sendFriendRequest(userId: UUID) async throws -> FriendRequestResult { try await inner.sendFriendRequest(userId: userId) }
    func acceptFriendRequest(id: UUID) async throws -> FriendRequests { try await inner.acceptFriendRequest(id: id) }
    func declineFriendRequest(id: UUID) async throws -> FriendRequests { try await inner.declineFriendRequest(id: id) }
    func removeFriend(userId: UUID) async throws { try await inner.removeFriend(userId: userId) }
    func blockUser(userId: UUID) async throws { try await inner.blockUser(userId: userId) }
    func feed(limit: Int?, cursor: String?) async throws -> Page<FeedEvent> { try await inner.feed(limit: limit, cursor: cursor) }
    func createParty(_ request: PartyCreate) async throws -> Party { try await inner.createParty(request) }
    func parties() async throws -> [Party] { try await inner.parties() }
    func party(id: UUID) async throws -> Party { try await inner.party(id: id) }
    func inviteToParty(id: UUID, userId: UUID) async throws -> Party { try await inner.inviteToParty(id: id, userId: userId) }
    func acceptPartyInvite(id: UUID) async throws -> Party { try await inner.acceptPartyInvite(id: id) }
    func leaveParty(id: UUID) async throws -> Party { try await inner.leaveParty(id: id) }
    func readyParty(id: UUID) async throws -> Party { try await inner.readyParty(id: id) }
    func startParty(id: UUID) async throws -> Party { try await inner.startParty(id: id) }
    func cancelParty(id: UUID) async throws -> Party { try await inner.cancelParty(id: id) }
    func stravaStatus() async throws -> StravaStatus { try await inner.stravaStatus() }
    func stravaAuthorize() async throws -> StravaAuthorizeResponse { try await inner.stravaAuthorize() }
    func stravaCallback(code: String) async throws -> StravaStatus { try await inner.stravaCallback(code: code) }
    func disconnectStrava() async throws { try await inner.disconnectStrava() }
    func uploadRideToStrava(rideId: UUID) async throws -> ProcessingStatus { try await inner.uploadRideToStrava(rideId: rideId) }
    func registerDevice(_ registration: DeviceRegistration) async throws { try await inner.registerDevice(registration) }
    func unregisterDevice(token: String) async throws { try await inner.unregisterDevice(token: token) }
    func config() async throws -> AppConfig { try await inner.config() }
    func health() async throws -> HealthStatus { try await inner.health() }
}

@MainActor
final class SyncServiceTests: XCTestCase {
    func testFailedUploadIsQueuedAndReplayed() async throws {
        let api = FlakyAPI()
        let container = AppContainer(api: api, inMemory: true)
        let sync = container.sync
        let point = RidePoint(latitude: 51.49, longitude: -0.04, timestamp: SampleData.referenceDate)
        await sync.uploadPoints(rideId: SampleData.rideId, rideClientId: SampleData.clientRideId, points: [point])
        XCTAssertEqual(container.persistence.pendingUploads().count, 1)
        XCTAssertEqual(api.uploadedBatches, 0)

        api.failUploads = false
        await sync.resumePendingUploads()
        XCTAssertEqual(container.persistence.pendingUploads().count, 0)
        XCTAssertEqual(api.uploadedBatches, 1)
    }

    func testRideCompletionPollsSummary() async throws {
        let api = MockAPI()
        api.summaryPollsBeforeReady = 0  // ready on the first poll; the default imitates server processing
        let container = AppContainer(api: api, inMemory: true)
        await container.session.bootstrap()
        let completion = RideComplete(endedAt: SampleData.referenceDate, distanceMeters: 1000, durationSeconds: 300)
        await container.sync.completeRide(rideId: SampleData.rideId, rideClientId: SampleData.clientRideId, completion: completion)
        // Polling runs in a task; the first poll returns the summary.
        for _ in 0..<50 where container.sync.latestSummary == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(container.sync.latestSummary)
    }
}
