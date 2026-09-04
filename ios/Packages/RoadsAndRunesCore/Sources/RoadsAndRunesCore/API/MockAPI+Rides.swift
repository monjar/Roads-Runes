import Foundation

// Rides, journal, discoveries, social, parties, integrations and meta endpoints.
extension MockAPI {
    // MARK: Rides

    public func createRide(_ request: RideCreate) async throws -> Ride {
        try await run {
            if let existing = self.storedRides.values.first(where: { $0.clientRideId == request.clientRideId }) { return existing }
            let ride = Ride(id: UUID(), clientRideId: request.clientRideId, status: .recording, startedAt: request.startedAt,
                            distanceMeters: 0, durationSeconds: 0, movingSeconds: 0, elevationGainMeters: 0, questId: request.questId,
                            bikeId: request.bikeId, routeId: request.routeId, visibility: self.user.settings.defaultRideVisibility,
                            pointCount: 0, flags: [], createdAt: Date())
            self.storedRides[ride.id] = ride
            return ride
        }
    }
    public func rides(limit: Int?, cursor: String?) async throws -> Page<Ride> {
        try await run { Page(items: Array(self.storedRides.values.sorted { $0.startedAt > $1.startedAt }.prefix(limit ?? 25))) }
    }
    public func ride(id: UUID) async throws -> Ride { try await run { try self.requireRide(id) } }
    public func uploadRidePoints(id: UUID, _ batch: RidePointsBatch) async throws -> Ride {
        try await run { var ride = try self.requireRide(id); ride.pointCount += batch.points.count; self.storedRides[id] = ride; return ride }
    }
    public func uploadRideExploration(id: UUID, _ batch: RideCellsBatch) async throws -> Ride {
        try await run {
            let ride = try self.requireRide(id)
            let known = Set(self.exploredCells.map { $0.h3 })
            for cell in batch.cellsVisited where !known.contains(cell) {
                self.exploredCells.append(ExplorationCell(h3: cell, state: .visited, firstVisitedAt: Date()))
            }
            return ride
        }
    }
    public func completeRide(id: UUID, _ completion: RideComplete) async throws -> RideCompleteResponse {
        try await run {
            var ride = try self.requireRide(id)
            ride.status = .processing
            ride.endedAt = completion.endedAt
            ride.distanceMeters = completion.distanceMeters
            ride.durationSeconds = completion.durationSeconds
            ride.movingSeconds = completion.movingSeconds ?? completion.durationSeconds
            ride.elevationGainMeters = completion.elevationGainMeters
            ride.activeCalories = completion.activeCalories
            ride.pointCount += completion.points.count
            ride.averageSpeedMps = ride.movingSeconds > 0 ? ride.distanceMeters / Double(ride.movingSeconds) : nil
            self.storedRides[id] = ride
            self.summaryPolls[id] = 0
            return RideCompleteResponse(ride: ride, processing: "QUEUED")
        }
    }
    public func rideSummary(id: UUID) async throws -> AdventureSummary? {
        try await run {
            var ride = try self.requireRide(id)
            let polls = self.summaryPolls[id, default: 0]
            if ride.status == .processing, polls < self.summaryPollsBeforeReady {
                self.summaryPolls[id] = polls + 1
                return nil
            }
            if ride.status == .processing || ride.status == .uploaded {
                ride.status = .processed
                self.storedRides[id] = ride
            }
            var summary = SampleData.sampleAdventureSummary
            summary.ride = ride
            summary.quest = ride.questId.flatMap { self.storedQuests[$0] }
            return summary
        }
    }
    public func rideGeometry(id: UUID) async throws -> RideGeometry {
        try await run {
            _ = try self.requireRide(id)
            return RideGeometry(coordinates: SampleData.sampleRoute.coordinates.map { Array($0.prefix(2)) }, encodedPolyline: SampleData.sampleRoute.encodedPolyline)
        }
    }
    public func updateRide(id: UUID, _ patch: RidePatch) async throws -> Ride {
        try await run {
            var ride = try self.requireRide(id)
            if let v = patch.visibility { ride.visibility = v }
            if let v = patch.title { ride.title = v }
            if let v = patch.notes { self.rideNotes[id] = v }
            self.storedRides[id] = ride
            return ride
        }
    }
    public func deleteRide(id: UUID) async throws { try await run { self.storedRides[id] = nil } }
    public func rideExportURL(id: UUID, format: RideExportFormat) -> URL {
        URL(string: "\(baseURL.absoluteString)/api/v1/rides/\(id.uuidString)/export?format=\(format.rawValue)") ?? baseURL
    }

    // MARK: Journal

    public func adventures(limit: Int?, cursor: String?) async throws -> Page<AdventureEntry> {
        try await run {
            let entries = self.storedRides.values
                .filter { $0.status == .processed || $0.status == .flagged }
                .sorted { $0.startedAt > $1.startedAt }
                .map { ride in
                    AdventureEntry(ride: ride, quest: ride.questId.flatMap { self.storedQuests[$0] }, xpAwarded: 420,
                                   discoveries: SampleData.sampleDiscoveries, newTerritoryMeters: 12600, newCells: 34,
                                   levelUps: [], notes: self.rideNotes[ride.id], photos: [])
                }
            return Page(items: Array(entries.prefix(limit ?? 25)))
        }
    }
    public func journalStats() async throws -> ExplorationStats { try await run { SampleData.sampleStats } }

    // MARK: Discoveries

    public func discoveries(near: Coordinate, radiusMeters: Double, category: DiscoveryCategory?, limit: Int?, cursor: String?) async throws -> Page<DiscoverySummary> {
        try await run {
            let items = self.storedDiscoveries.values
                .filter { category == nil || $0.category == category }
                .filter { GeoMath.distance(near, $0.coordinate) <= radiusMeters }
                .sorted { $0.name < $1.name }
                .map { $0.summary }
            return Page(items: Array(items.prefix(limit ?? 25)))
        }
    }
    public func discovery(id: UUID) async throws -> Discovery {
        try await run {
            guard var discovery = self.storedDiscoveries[id] else { throw self.notFound("Discovery") }
            discovery.userDiscovery = self.userDiscoveries[id]
            return discovery
        }
    }
    public func myDiscoveries(limit: Int?, cursor: String?) async throws -> Page<UserDiscovery> {
        try await run { Page(items: self.userDiscoveries.values.sorted { $0.discoveredAt > $1.discoveredAt }) }
    }
    public func updateUserDiscovery(id: UUID, _ update: UserDiscoveryIn) async throws -> UserDiscovery {
        try await run {
            guard self.storedDiscoveries[id] != nil else { throw self.notFound("Discovery") }
            var record = self.userDiscoveries[id] ?? UserDiscovery(discoveryId: id, discoveredAt: Date())
            record.note = update.note
            record.rating = update.rating
            record.tags = update.tags
            record.photoIds = update.photoIds
            if let visibility = update.visibility { record.visibility = visibility }
            self.userDiscoveries[id] = record
            return record
        }
    }
    public func createDiscovery(_ request: DiscoveryCreate) async throws -> Discovery {
        try await run {
            let discovery = Discovery(id: UUID(), name: request.name, category: request.category, latitude: request.latitude, longitude: request.longitude,
                                      source: .user, discoveredByUser: true, discoveredAt: Date(), description: request.description)
            self.storedDiscoveries[discovery.id] = discovery
            return discovery
        }
    }

    // MARK: Friends & feed

    public func friends() async throws -> [FriendSummary] { try await run { self.storedFriends } }
    public func friendRequests() async throws -> FriendRequests { try await run { self.storedRequests } }
    public func sendFriendRequest(userId: UUID) async throws -> FriendRequestResult {
        try await run {
            let request = FriendRequest(id: UUID(), user: FriendSummary(id: userId, displayName: "Rider \(userId.uuidString.prefix(4))"), createdAt: Date())
            self.storedRequests.outgoing.append(request)
            return FriendRequestResult(id: request.id, status: "PENDING")
        }
    }
    public func acceptFriendRequest(id: UUID) async throws -> FriendRequests {
        try await run {
            if let index = self.storedRequests.incoming.firstIndex(where: { $0.id == id }) {
                let request = self.storedRequests.incoming.remove(at: index)
                self.storedFriends.append(request.user)
            }
            return self.storedRequests
        }
    }
    public func declineFriendRequest(id: UUID) async throws -> FriendRequests {
        try await run { self.storedRequests.incoming.removeAll { $0.id == id }; return self.storedRequests }
    }
    public func removeFriend(userId: UUID) async throws { try await run { self.storedFriends.removeAll { $0.id == userId } } }
    public func blockUser(userId: UUID) async throws { try await run { self.storedFriends.removeAll { $0.id == userId } } }
    public func feed(limit: Int?, cursor: String?) async throws -> Page<FeedEvent> {
        try await run {
            Page(items: [FeedEvent(id: UUID(), eventType: .friendQuestCompleted, user: SampleData.sampleFriend,
                                   payload: ["questTitle": "The Quiet Lanes", "difficulty": "EASY"], createdAt: Date())])
        }
    }

    // MARK: Parties

    public func createParty(_ request: PartyCreate) async throws -> Party {
        try await run {
            var party = SampleData.sampleParty
            party.id = UUID()
            party.questId = request.questId
            party.createdAt = Date()
            self.storedParties[party.id] = party
            return party
        }
    }
    public func parties() async throws -> [Party] { try await run { self.storedParties.values.sorted { $0.createdAt > $1.createdAt } } }
    public func party(id: UUID) async throws -> Party { try await run { try self.requireParty(id) } }
    public func inviteToParty(id: UUID, userId: UUID) async throws -> Party {
        try await run {
            var party = try self.requireParty(id)
            party.members.append(PartyMember(user: FriendSummary(id: userId, displayName: "Invited rider"), role: "MEMBER", status: "INVITED"))
            self.storedParties[id] = party
            return party
        }
    }
    public func acceptPartyInvite(id: UUID) async throws -> Party { try await run { try self.requireParty(id) } }
    public func leaveParty(id: UUID) async throws -> Party { try await run { try self.requireParty(id) } }
    public func readyParty(id: UUID) async throws -> Party { try await setPartyStatus(id, .ready) }
    public func startParty(id: UUID) async throws -> Party { try await setPartyStatus(id, .active) }
    public func cancelParty(id: UUID) async throws -> Party { try await setPartyStatus(id, .cancelled) }

    func setPartyStatus(_ id: UUID, _ status: PartyStatus) async throws -> Party {
        try await run {
            var party = try self.requireParty(id)
            party.status = status
            self.storedParties[id] = party
            return party
        }
    }

    // MARK: Integrations

    public func stravaStatus() async throws -> StravaStatus { try await run { self.strava } }
    public func stravaAuthorize() async throws -> StravaAuthorizeResponse {
        try await run { StravaAuthorizeResponse(url: "https://www.strava.com/oauth/authorize?client_id=mock") }
    }
    public func stravaCallback(code: String) async throws -> StravaStatus {
        try await run { self.strava = StravaStatus(connected: true, athleteName: "Amir M.", uploadMode: self.user.settings.stravaUploadMode, enabled: true); return self.strava }
    }
    public func disconnectStrava() async throws { try await run { self.strava = StravaStatus(connected: false, uploadMode: .never, enabled: true) } }
    public func uploadRideToStrava(rideId: UUID) async throws -> ProcessingStatus { try await run { ProcessingStatus(status: "QUEUED") } }

    // MARK: Devices & meta

    public func registerDevice(_ registration: DeviceRegistration) async throws { try await run {} }
    public func unregisterDevice(token: String) async throws { try await run {} }
    public func config() async throws -> AppConfig { try await run { SampleData.sampleConfig } }
    public func health() async throws -> HealthStatus { try await run { HealthStatus(status: "ok", version: "mock") } }
}
