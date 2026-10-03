import Foundation

/// Something placed in this player's world: a chest to pass, a piece to gather, a monster to beat.
public enum WorldObjectKind: String, SafeEnum {
    case chest = "CHEST"
    case collectable = "COLLECTABLE"
    case monster = "MONSTER"
    case unknown = "UNKNOWN"
}

public enum WorldObjectStatus: String, SafeEnum {
    case spawned = "SPAWNED"
    case claimed = "CLAIMED"
    case expired = "EXPIRED"
    case unknown = "UNKNOWN"
}

/// How a monster can be beaten. The numbers were resolved for this player on the server.
public enum KillMethodKind: String, SafeEnum {
    case pace = "PACE"
    case rune = "RUNE"
    case climb = "CLIMB"
    case lore = "LORE"
    case explore = "EXPLORE"
    case unknown = "UNKNOWN"
}

public struct KillMethod: Codable, Hashable, Sendable {
    public var method: KillMethodKind
    public var params: [String: JSONValue]
    public var hint: String

    public init(method: KillMethodKind, params: [String: JSONValue] = [:], hint: String) {
        self.method = method
        self.params = params
        self.hint = hint
    }

    public func double(_ key: String) -> Double? {
        params[key]?.doubleValue ?? params[key]?.intValue.map(Double.init)
    }
}

public struct MonsterInfo: Codable, Hashable, Sendable {
    public var hp: Int
    public var flavour: String?
    public var killMethods: [KillMethod]
    /// Which creature it is and its face; nil from servers before 0.6.0.
    public var speciesId: String?
    public var sigil: CreatureSigil?

    public init(hp: Int, flavour: String? = nil, killMethods: [KillMethod] = [], speciesId: String? = nil, sigil: CreatureSigil? = nil) {
        self.hp = hp
        self.flavour = flavour
        self.killMethods = killMethods
        self.speciesId = speciesId
        self.sigil = sigil
    }
}

public struct WorldObject: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: WorldObjectKind
    public var status: WorldObjectStatus
    public var tier: Int
    public var latitude: Double
    public var longitude: Double
    public var name: String
    public var anchorName: String?
    public var bounty: Bool?
    public var rewardAC: Int
    public var expiresAt: Date
    public var claimedAt: Date?
    public var monster: MonsterInfo?
    public var setId: String?
    public var piece: String?
    /// How close the player must be to open or pick it up; nil for a monster (and from an older server).
    public var claimRadiusMeters: Double?
    /// The set a piece belongs to, how many pieces it has, and how many different ones the player holds.
    public var setName: String?
    public var setSize: Int?
    public var setOwned: Int?
    /// The player already holds this very piece: picking it up is coins, not progress.
    public var pieceOwned: Bool?

    public init(id: UUID, kind: WorldObjectKind, status: WorldObjectStatus = .spawned, tier: Int = 1, latitude: Double, longitude: Double, name: String, anchorName: String? = nil, bounty: Bool? = nil, rewardAC: Int, expiresAt: Date, claimedAt: Date? = nil, monster: MonsterInfo? = nil, setId: String? = nil, piece: String? = nil, claimRadiusMeters: Double? = nil, setName: String? = nil, setSize: Int? = nil, setOwned: Int? = nil) {
        self.setName = setName
        self.setSize = setSize
        self.setOwned = setOwned
        self.id = id
        self.kind = kind
        self.status = status
        self.tier = tier
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.anchorName = anchorName
        self.bounty = bounty
        self.rewardAC = rewardAC
        self.expiresAt = expiresAt
        self.claimedAt = claimedAt
        self.monster = monster
        self.setId = setId
        self.piece = piece
        self.claimRadiusMeters = claimRadiusMeters
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public var isBounty: Bool { bounty ?? false }

    /// "Old Runes, 3 of 6": where a piece stands in its set, once the player's count is known.
    public var setStanding: SetStanding? {
        guard let setName, let setSize, let setOwned else { return nil }
        return SetStanding(name: setName, owned: setOwned, of: setSize)
    }

    /// Where the set will stand once this piece is picked up: one more, unless it is a second of the same.
    public var setStandingOnceTaken: SetStanding? {
        guard var standing = setStanding else { return nil }
        if pieceOwned != true { standing.owned = min(standing.of, standing.owned + 1) }
        return standing
    }

    /// Radii used when the server does not say: the same numbers it holds.
    public static let defaultClaimRadius: [WorldObjectKind: Double] = [.chest: 40, .collectable: 30]

    /// Within this many metres a chest opens or a piece is picked up; nil for what cannot be taken by hand.
    public var reachMeters: Double? { claimRadiusMeters ?? Self.defaultClaimRadius[kind] }

    /// Whether someone standing at `position` can reach for it.
    public func isWithinReach(of position: Coordinate) -> Bool {
        guard status == .spawned, let reach = reachMeters else { return false }
        return GeoMath.distance(position, coordinate) <= reach
    }
}

/// `POST /world/objects/{id}/claim`: where the phone says the player is standing.
public struct WorldObjectClaimRequest: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracyMeters: Double?

    public init(latitude: Double, longitude: Double, horizontalAccuracyMeters: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }
}

/// How many different pieces of a set the player holds.
public struct SetStanding: Hashable, Sendable {
    public var name: String
    public var owned: Int
    public var of: Int

    public init(name: String, owned: Int, of: Int) {
        self.name = name
        self.owned = owned
        self.of = of
    }

    public var isComplete: Bool { owned >= of }
    /// "Old Runes, 3 of 6" / "Old Runes complete".
    public var line: String { isComplete ? "\(name) complete" : "\(name), \(owned) of \(of)" }
}

/// A set made whole, and the purse for it.
public struct CompletedSet: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var bonusAC: Int

    public init(id: String, name: String, bonusAC: Int) {
        self.id = id
        self.name = name
        self.bonusAC = bonusAC
    }
}

/// What opening a chest or picking up a piece gave.
public struct WorldObjectClaim: Codable, Hashable, Sendable {
    public var object: WorldObject
    public var acAwarded: Int
    public var walletBalance: Int
    /// The quest this finished, when it was the last thing a quest asked for.
    public var questCompleted: Quest?
    public var xpAwarded: Int?
    public var levelUps: [LevelUp]?
    /// The set this piece finished.
    public var setCompleted: CompletedSet?

    public init(object: WorldObject, acAwarded: Int, walletBalance: Int, questCompleted: Quest? = nil, xpAwarded: Int? = nil, levelUps: [LevelUp]? = nil, setCompleted: CompletedSet? = nil) {
        self.object = object
        self.acAwarded = acAwarded
        self.walletBalance = walletBalance
        self.questCompleted = questCompleted
        self.xpAwarded = xpAwarded
        self.levelUps = levelUps
        self.setCompleted = setCompleted
    }
}

/// The phone's word that it beat or opened something on the way; the server's trace has the last word.
public struct EncounterEvent: Codable, Hashable, Sendable {
    public var objectId: UUID
    public var method: String
    public var occurredAt: Date
    public var latitude: Double?
    public var longitude: Double?
    public var note: String?
    public var photoTaken: Bool?

    public init(objectId: UUID, method: String, occurredAt: Date, latitude: Double? = nil, longitude: Double? = nil, note: String? = nil, photoTaken: Bool? = nil) {
        self.objectId = objectId
        self.method = method
        self.occurredAt = occurredAt
        self.latitude = latitude
        self.longitude = longitude
        self.note = note
        self.photoTaken = photoTaken
    }
}

public struct ClaimedObject: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: WorldObjectKind
    public var name: String
    public var tier: Int?
    public var rewardAC: Int
    public var method: String?
    public var setId: String?
    public var piece: String?
    public var setName: String?
    public var setSize: Int?
    public var setOwned: Int?

    public init(id: UUID, kind: WorldObjectKind, name: String, tier: Int? = nil, rewardAC: Int, method: String? = nil, setId: String? = nil, piece: String? = nil, setName: String? = nil, setSize: Int? = nil, setOwned: Int? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.tier = tier
        self.rewardAC = rewardAC
        self.method = method
        self.setId = setId
        self.piece = piece
        self.setName = setName
        self.setSize = setSize
        self.setOwned = setOwned
    }

    public var setStanding: SetStanding? {
        guard let setName, let setSize, let setOwned else { return nil }
        return SetStanding(name: setName, owned: setOwned, of: setSize)
    }
}

/// How near a monster that got away came to being beaten: the nearest of its ways,
/// with what it wanted and what the ride gave it. `progress` is 1 at the target.
public struct MissedAttempt: Codable, Hashable, Sendable {
    public var method: KillMethodKind
    public var progress: Double?
    public var paceSecPerKm: Double?
    public var targetSecPerKm: Double?
    public var windowMeters: Double?
    public var gainMeters: Double?
    public var targetGainMeters: Double?
    public var cells: Int?
    public var targetCells: Int?

    public init(method: KillMethodKind, progress: Double? = nil, paceSecPerKm: Double? = nil, targetSecPerKm: Double? = nil, windowMeters: Double? = nil, gainMeters: Double? = nil, targetGainMeters: Double? = nil, cells: Int? = nil, targetCells: Int? = nil) {
        self.method = method
        self.progress = progress
        self.paceSecPerKm = paceSecPerKm
        self.targetSecPerKm = targetSecPerKm
        self.windowMeters = windowMeters
        self.gainMeters = gainMeters
        self.targetGainMeters = targetGainMeters
        self.cells = cells
        self.targetCells = targetCells
    }
}

public struct MissedObject: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: WorldObjectKind
    public var name: String
    public var reason: String
    public var expiresAt: Date?
    public var attempt: MissedAttempt?

    public init(id: UUID, kind: WorldObjectKind, name: String, reason: String, expiresAt: Date? = nil, attempt: MissedAttempt? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.reason = reason
        self.expiresAt = expiresAt
        self.attempt = attempt
    }
}

/// What a processed ride said about the world: what it took, and what it walked past.
public struct WorldObjectOutcome: Codable, Hashable, Sendable {
    public var claimed: [ClaimedObject]
    public var missed: [MissedObject]
    public var setsCompleted: [CompletedSet]?

    public init(claimed: [ClaimedObject] = [], missed: [MissedObject] = [], setsCompleted: [CompletedSet]? = nil) {
        self.claimed = claimed
        self.missed = missed
        self.setsCompleted = setsCompleted
    }
}

/// What a processed ride said about the days in a row.
public struct StreakOutcome: Codable, Hashable, Sendable {
    public var days: Int
    public var longest: Int
    public var extended: Bool
    public var milestone: Int?
    public var bonusAC: Int

    public init(days: Int, longest: Int, extended: Bool, milestone: Int? = nil, bonusAC: Int = 0) {
        self.days = days
        self.longest = longest
        self.extended = extended
        self.milestone = milestone
        self.bonusAC = bonusAC
    }
}

/// `POST /world/objects/lure`.
public struct LureRequest: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
