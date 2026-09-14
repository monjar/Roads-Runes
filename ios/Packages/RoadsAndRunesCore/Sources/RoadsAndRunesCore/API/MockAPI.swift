import Foundation

/// In-memory `RoadsAndRunesAPI` for previews and tests. State changes are
/// serialised with a lock so it can be used from any task.
public final class MockAPI: RoadsAndRunesAPI, @unchecked Sendable {
    public let baseURL = URL(string: "https://mock.roadsandrunes.local")!

    /// Number of `rideSummary` polls that return `nil` (202) before the summary is ready.
    public var summaryPollsBeforeReady = 1
    /// Simulated latency per call, in seconds (0 in tests).
    public var latency: TimeInterval = 0
    /// If set, the next call throws this error once.
    public var failNext: APIError?

    let lock = NSLock()
    var user: User
    var storedCharacter: Character?
    var storedCoins = 0
    var storedTransactions: [WalletTransaction] = []
    var storedObjects: [UUID: WorldObject] = Dictionary(uniqueKeysWithValues: SampleData.sampleObjects.map { ($0.id, $0) })
    var storedBikes: [Bike]
    var storedRiderProfile: RiderProfile
    var storedQuests: [UUID: Quest]
    var storedRoutes: [UUID: RouteOption]
    var storedRides: [UUID: Ride]
    var rideNotes: [UUID: String] = [:]
    var summaryPolls: [UUID: Int] = [:]
    var storedDiscoveries: [UUID: Discovery]
    var userDiscoveries: [UUID: UserDiscovery] = [:]
    var storedFriends: [FriendSummary]
    var storedRequests = FriendRequests()
    var storedParties: [UUID: Party]
    var strava = StravaStatus(connected: false, uploadMode: .never, enabled: true)
    var exploredCells: [ExplorationCell]

    public init(hasCharacter: Bool = true) {
        var user = SampleData.sampleUser
        user.hasCharacter = hasCharacter
        self.user = user
        storedCharacter = hasCharacter ? SampleData.sampleCharacter : nil
        storedBikes = [SampleData.sampleBike]
        storedRiderProfile = SampleData.sampleRiderProfile
        storedQuests = [SampleData.sampleQuest.id: SampleData.sampleQuest]
        storedRoutes = [SampleData.sampleRoute.id: SampleData.sampleRoute]
        storedRides = [SampleData.sampleRide.id: SampleData.sampleRide]
        storedDiscoveries = Dictionary(uniqueKeysWithValues: SampleData.sampleDiscoveries.map { summary in
            (summary.id, Discovery(id: summary.id, name: summary.name, category: summary.category, latitude: summary.latitude,
                                   longitude: summary.longitude, source: summary.source, discoveredByUser: summary.discoveredByUser,
                                   discoveredAt: summary.discoveredAt, description: "A place worth a detour."))
        })
        storedFriends = [SampleData.sampleFriend]
        storedParties = [SampleData.sampleParty.id: SampleData.sampleParty]
        exploredCells = SampleData.sampleWorld.cells
    }

    // MARK: Helpers

    func run<T>(_ body: () throws -> T) async throws -> T {
        if latency > 0 {
            try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        }
        lock.lock()
        defer { lock.unlock() }
        if let error = failNext {
            failNext = nil
            throw error
        }
        return try body()
    }

    func notFound(_ what: String) -> APIError {
        .server(code: APIErrorCode.notFound, message: "\(what) not found", status: 404)
    }

    func invalidTransition(_ from: QuestStatus, _ to: QuestStatus) -> APIError {
        .server(code: APIErrorCode.questInvalidTransition, message: "Quest cannot move from \(from.rawValue) to \(to.rawValue)", status: 409)
    }

    func tokens() -> TokenResponse {
        TokenResponse(accessToken: "mock-access-token", refreshToken: "mock-refresh-token", expiresIn: 3600, isNewUser: false, user: user)
    }

    func requireCharacter() throws -> Character {
        guard let character = storedCharacter else { throw notFound("Character") }
        return character
    }

    func requireQuest(_ id: UUID) throws -> Quest {
        guard let quest = storedQuests[id] else { throw notFound("Quest") }
        return quest
    }

    func requireRide(_ id: UUID) throws -> Ride {
        guard let ride = storedRides[id] else { throw notFound("Ride") }
        return ride
    }

    func requireParty(_ id: UUID) throws -> Party {
        guard let party = storedParties[id] else { throw notFound("Party") }
        return party
    }

    // MARK: Auth

    public func signInWithApple(_ request: AppleSignInRequest) async throws -> TokenResponse { try await run { self.tokens() } }
    public func refresh(_ request: RefreshRequest) async throws -> TokenResponse { try await run { self.tokens() } }
    public func devSignIn(_ request: DevSignInRequest) async throws -> TokenResponse {
        try await run {
            self.user.displayName = request.displayName
            return self.tokens()
        }
    }
    public func logout() async throws { try await run {} }

    // MARK: Users

    public func me() async throws -> User { try await run { self.user } }
    public func updateMe(_ update: UserUpdate) async throws -> User {
        try await run {
            if let name = update.displayName { self.user.displayName = name }
            if let avatar = update.avatarUrl { self.user.avatarUrl = avatar }
            if let settings = update.settings { self.user.settings = settings }
            return self.user
        }
    }
    public func profile(userId: UUID) async throws -> PublicProfile {
        try await run {
            let isMe = userId == self.user.id
            return PublicProfile(
                id: userId, displayName: isMe ? self.user.displayName : "Bea", characterClass: .explorer,
                overallLevel: isMe ? self.storedCharacter?.overallLevel : 5, title: isMe ? self.storedCharacter?.title : "Pathfinder",
                questsCompleted: 12, discoveriesFound: 30, favouriteTerrain: "GRAVEL", friendship: isMe ? FriendshipState.none : FriendshipState.friends,
                recentAdventures: [
                    AdventureSummaryPublic(
                        rideId: SampleData.rideId, questTitle: "Beyond the Water", completedAt: SampleData.referenceDate,
                        distanceMeters: 32400, newTerritoryMeters: 12600, xpAwarded: 420
                    ),
                ]
            )
        }
    }

    // MARK: Character

    public func classes() async throws -> [ClassInfo] { try await run { SampleData.sampleClasses } }
    public func createCharacter(_ request: CharacterCreate) async throws -> Character {
        try await run {
            if self.storedCharacter != nil {
                throw APIError.server(code: APIErrorCode.conflict, message: "Character exists", status: 409)
            }
            var character = SampleData.sampleCharacter
            character.name = request.name
            character.characterClass = request.characterClass
            character.overallLevel = 1; character.overallXP = 0; character.overallLevelFloorXP = 0; character.nextOverallLevelXP = 100
            character.classLevel = 1; character.classXP = 0; character.classLevelFloorXP = 0; character.nextClassLevelXP = 100
            character.title = nil
            character.unspentAbilityPoints = 0
            self.storedCharacter = character
            self.user.hasCharacter = true
            return character
        }
    }
    public func character() async throws -> Character { try await run { try self.requireCharacter() } }
    public func changeClass(_ request: CharacterClassChange) async throws -> Character {
        try await run {
            var character = try self.requireCharacter()
            if character.characterClass == request.characterClass {
                throw APIError.server(code: "SAME_CLASS", message: "Already that class", status: 409)
            }
            let cost = character.classChangeCostAC ?? 0
            if cost > self.storedCoins {
                throw APIError.server(code: "INSUFFICIENT_AC", message: "That costs \(cost) Active Coins and you have \(self.storedCoins)", status: 409)
            }
            var progress = character.classProgress ?? [:]
            progress[character.characterClass.rawValue] = ClassProgress(classXp: character.classXP, classLevel: character.classLevel)
            let restored = progress[request.characterClass.rawValue]
            character.classXP = restored?.classXp ?? 0
            character.classLevel = restored?.classLevel ?? 1
            character.classProgress = progress
            character.characterClass = request.characterClass
            character.classChanges = (character.classChanges ?? 0) + 1
            character.classChangeCostAC = 150
            character.nextClassChangeAt = Date().addingTimeInterval(24 * 3600)
            if cost > 0 {
                self.storedCoins -= cost
                self.storedTransactions.insert(WalletTransaction(id: UUID(), amount: -cost, kind: .classChange, createdAt: Date()), at: 0)
            }
            character.activeCoins = self.storedCoins
            self.storedCharacter = character
            return character
        }
    }
    public func resetCharacter() async throws {
        try await run {
            _ = try self.requireCharacter()
            self.storedCharacter = nil
            self.storedCoins = 0
            self.storedTransactions = []
            self.user.hasCharacter = false
        }
    }
    public func wallet() async throws -> Wallet {
        try await run { Wallet(balance: self.storedCoins, lifetimeEarned: self.storedTransactions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }) }
    }
    public func walletTransactions(limit: Int?, cursor: String?) async throws -> Page<WalletTransaction> {
        try await run { Page(items: Array(self.storedTransactions.prefix(limit ?? 25)), nextCursor: nil) }
    }
    public func worldObjects(near center: Coordinate, radiusMeters: Double) async throws -> [WorldObject] {
        try await run { self.storedObjects.values.filter { $0.status == .spawned && GeoMath.distance(center, $0.coordinate) <= radiusMeters } }
    }
    public func worldObject(id: UUID) async throws -> WorldObject {
        try await run { try self.storedObjects[id] ?? { throw self.notFound("World object") }() }
    }
    public func bounty() async throws -> WorldObject? {
        try await run { self.storedObjects.values.first { $0.isBounty && $0.status == .spawned } }
    }
    public func lure(at center: Coordinate) async throws -> [WorldObject] {
        try await run {
            if self.storedCoins < 50 {
                throw APIError.server(code: "INSUFFICIENT_AC", message: "That costs 50 Active Coins and you have \(self.storedCoins)", status: 409)
            }
            self.storedCoins -= 50
            let lured = WorldObject(id: UUID(), kind: .monster, latitude: center.latitude + 0.004, longitude: center.longitude + 0.003, name: "Lured Fen Troll", anchorName: "the towpath", rewardAC: 60, expiresAt: Date().addingTimeInterval(3 * 86_400), monster: SampleData.sampleMonster.monster)
            self.storedObjects[lured.id] = lured
            return self.storedObjects.values.filter { $0.status == .spawned }
        }
    }
    public func abilities() async throws -> [AbilityState] { try await run { try self.requireCharacter().abilities } }
    public func unlockAbility(id: String) async throws -> Character {
        try await run {
            var character = try self.requireCharacter()
            guard let index = character.abilities.firstIndex(where: { $0.ability.id == id }) else { throw self.notFound("Ability") }
            guard character.abilities[index].canUnlock, character.unspentAbilityPoints > 0 else {
                throw APIError.server(code: APIErrorCode.conflict, message: "Ability cannot be unlocked", status: 409)
            }
            character.abilities[index].rank += 1
            character.abilities[index].unlocked = true
            character.abilities[index].canUnlock = character.abilities[index].rank < character.abilities[index].ability.maxRank
            character.unspentAbilityPoints -= 1
            self.storedCharacter = character
            return character
        }
    }
    public func bikes() async throws -> [Bike] { try await run { self.storedBikes } }
    public func createBike(_ bike: BikeIn) async throws -> Bike {
        try await run {
            let created = Bike(id: UUID(), name: bike.name ?? "Bike", bikeType: bike.bikeType ?? .other, allowGravel: bike.allowGravel ?? false,
                               allowTrails: bike.allowTrails ?? false, maxTechnicalSurface: bike.maxTechnicalSurface ?? 0, isDefault: bike.isDefault ?? false)
            if created.isDefault { for i in self.storedBikes.indices { self.storedBikes[i].isDefault = false } }
            self.storedBikes.append(created)
            return created
        }
    }
    public func updateBike(id: UUID, _ patch: BikeIn) async throws -> Bike {
        try await run {
            guard let index = self.storedBikes.firstIndex(where: { $0.id == id }) else { throw self.notFound("Bike") }
            var bike = self.storedBikes[index]
            if let v = patch.name { bike.name = v }
            if let v = patch.bikeType { bike.bikeType = v }
            if let v = patch.allowGravel { bike.allowGravel = v }
            if let v = patch.allowTrails { bike.allowTrails = v }
            if let v = patch.maxTechnicalSurface { bike.maxTechnicalSurface = v }
            if let v = patch.isDefault { bike.isDefault = v }
            self.storedBikes[index] = bike
            return bike
        }
    }
    public func deleteBike(id: UUID) async throws { try await run { self.storedBikes.removeAll { $0.id == id } } }
    public func riderProfile() async throws -> RiderProfile { try await run { self.storedRiderProfile } }
    public func updateRiderProfile(_ profile: RiderProfile) async throws -> RiderProfile {
        try await run { self.storedRiderProfile = profile; return profile }
    }

    // MARK: World

    public func world(center: Coordinate, radiusMeters: Double) async throws -> WorldSnapshot {
        try await run {
            var world = SampleData.sampleWorld
            world.center = center
            world.cells = self.exploredCells
            world.questMarkers = self.storedQuests.values.filter { $0.status == .available || $0.status == .accepted || $0.status == .active }.map {
                QuestMarker(questId: $0.id, title: $0.title, latitude: $0.origin.latitude, longitude: $0.origin.longitude,
                            difficulty: $0.difficulty, questType: $0.questType, status: $0.status)
            }
            world.objects = self.storedObjects.values.filter { $0.status == .spawned }
            return world
        }
    }
    public func exploration(in box: BoundingBox) async throws -> ExplorationResponse {
        try await run { ExplorationResponse(h3Resolution: 9, cells: self.exploredCells) }
    }
    public func explorationStats() async throws -> ExplorationStats { try await run { SampleData.sampleStats } }

    // MARK: Quests

    public func quests(near: Coordinate, status: QuestStatus?, limit: Int?, cursor: String?) async throws -> Page<Quest> {
        try await run {
            let items = self.storedQuests.values
                .filter { status == nil || $0.status == status }
                .sorted { ($0.createdAt ?? .distantPast, $0.id.uuidString) < ($1.createdAt ?? .distantPast, $1.id.uuidString) }
            return Page(items: Array(items.prefix(limit ?? 25)))
        }
    }
    public func generateQuests(_ request: QuestGenerateRequest) async throws -> Page<Quest> {
        try await run {
            let titles = ["Beyond the Water", "The Quiet Lanes", "Hill of the Old Beacon", "Towpath Circuit", "Lost Orchard", "Gravel Vespers"]
            var generated: [Quest] = []
            for index in 0..<max(1, min(request.count, 6)) {
                var quest = SampleData.sampleQuest
                quest.id = UUID()
                quest.title = titles[index % titles.count]
                quest.origin = Coordinate(latitude: request.latitude, longitude: request.longitude)
                quest.objectives = quest.objectives.map { objective in
                    var copy = objective
                    copy.id = UUID()
                    return copy
                }
                quest.createdAt = Date()
                self.storedQuests[quest.id] = quest
                generated.append(quest)
            }
            return Page(items: generated)
        }
    }
    public func quest(id: UUID) async throws -> Quest { try await run { try self.requireQuest(id) } }
    public func acceptQuest(id: UUID) async throws -> Quest {
        try await run {
            var quest = try self.requireQuest(id)
            guard quest.status == .available else { throw self.invalidTransition(quest.status, .accepted) }
            quest.status = .accepted
            quest.acceptedAt = Date()
            self.storedQuests[id] = quest
            return quest
        }
    }
    public func startQuest(id: UUID, rideId: UUID?) async throws -> Quest {
        try await run {
            var quest = try self.requireQuest(id)
            guard quest.status == .accepted else { throw self.invalidTransition(quest.status, .active) }
            quest.status = .active
            quest.startedAt = Date()
            quest.rideId = rideId
            self.storedQuests[id] = quest
            return quest
        }
    }
    public func reportQuestProgress(id: UUID, events: [ObjectiveEvent]) async throws -> Quest {
        try await run {
            var quest = try self.requireQuest(id)
            for event in events {
                if let index = quest.objectives.firstIndex(where: { $0.id == event.objectiveId }) {
                    quest.objectives[index].status = .completed
                    quest.objectives[index].completedAt = event.occurredAt
                    quest.objectives[index].provisional = true
                    quest.objectives[index].progress.current = quest.objectives[index].progress.target
                }
            }
            self.storedQuests[id] = quest
            return quest
        }
    }
    public func completeQuest(id: UUID, rideId: UUID?) async throws -> QuestCompletion {
        try await run {
            var quest = try self.requireQuest(id)
            guard quest.status == .active else { throw self.invalidTransition(quest.status, .completed) }
            quest.status = .completed
            quest.completedAt = Date()
            self.storedQuests[id] = quest
            if var character = self.storedCharacter {
                character.overallXP += quest.baseXP
                character.classXP += quest.baseXP / 2
                self.storedCharacter = character
            }
            return QuestCompletion(quest: quest, xpAwarded: quest.baseXP + quest.baseXP / 5,
                                   xpBreakdown: [XPBreakdownEntry(source: "QUEST_COMPLETED", xp: quest.baseXP), XPBreakdownEntry(source: "CLASS_BONUS", xp: quest.baseXP / 5)],
                                   levelUps: [], abilitiesUnlocked: [], titlesUnlocked: [])
        }
    }
    public func abandonQuest(id: UUID) async throws -> Quest {
        try await run {
            var quest = try self.requireQuest(id)
            guard quest.status == .accepted || quest.status == .active else { throw self.invalidTransition(quest.status, .abandoned) }
            quest.status = .abandoned
            self.storedQuests[id] = quest
            return quest
        }
    }

    // MARK: Routes

    public func questRoute(id: UUID) async throws -> RouteOption {
        try await run {
            var quest = try self.requireQuest(id)
            if let routeId = quest.suggestedRouteId, let route = self.storedRoutes[routeId] { return route }
            var route = SampleData.sampleRoute
            route.id = UUID()
            route.label = "Adventure"
            self.storedRoutes[route.id] = route
            quest.suggestedRouteId = route.id
            self.storedQuests[id] = quest
            return route
        }
    }

    public func generateRoutes(_ request: RouteGenerateRequest) async throws -> RouteGenerateResponse {
        try await run {
            let variants: [(String, Double, Double)] = [("Adventure", 1.0, 0.81), ("Direct", 0.85, 0.74), ("Scenic", 1.15, 0.78)]
            let alternatives = variants.map { label, scale, score -> RouteOption in
                var route = SampleData.sampleRoute
                route.id = UUID()
                route.label = label
                route.distanceMeters = (route.distanceMeters * scale).rounded()
                route.estimatedDurationSeconds = Int(Double(route.estimatedDurationSeconds) * scale)
                route.score = score
                self.storedRoutes[route.id] = route
                return route
            }
            return RouteGenerateResponse(alternatives: alternatives, parsedRequest: request.request == nil ? nil : ["trafficAversion": .number(0.8)], engine: "synthetic")
        }
    }
    public func route(id: UUID) async throws -> RouteOption {
        try await run { guard let route = self.storedRoutes[id] else { throw self.notFound("Route") }; return route }
    }
    public func routePackage(id: UUID) async throws -> RoutePackage {
        try await run {
            guard let route = self.storedRoutes[id] else { throw self.notFound("Route") }
            var package = SampleData.sampleRoutePackage
            package.route = route
            return package
        }
    }
}
