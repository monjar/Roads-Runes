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

    public init(hp: Int, flavour: String? = nil, killMethods: [KillMethod] = []) {
        self.hp = hp
        self.flavour = flavour
        self.killMethods = killMethods
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

    public init(id: UUID, kind: WorldObjectKind, status: WorldObjectStatus = .spawned, tier: Int = 1, latitude: Double, longitude: Double, name: String, anchorName: String? = nil, bounty: Bool? = nil, rewardAC: Int, expiresAt: Date, claimedAt: Date? = nil, monster: MonsterInfo? = nil, setId: String? = nil, piece: String? = nil) {
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
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public var isBounty: Bool { bounty ?? false }
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

    public init(id: UUID, kind: WorldObjectKind, name: String, tier: Int? = nil, rewardAC: Int, method: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.tier = tier
        self.rewardAC = rewardAC
        self.method = method
    }
}

public struct MissedObject: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: WorldObjectKind
    public var name: String
    public var reason: String

    public init(id: UUID, kind: WorldObjectKind, name: String, reason: String) {
        self.id = id
        self.kind = kind
        self.name = name
        self.reason = reason
    }
}

/// What a processed ride said about the world: what it took, and what it walked past.
public struct WorldObjectOutcome: Codable, Hashable, Sendable {
    public var claimed: [ClaimedObject]
    public var missed: [MissedObject]

    public init(claimed: [ClaimedObject] = [], missed: [MissedObject] = []) {
        self.claimed = claimed
        self.missed = missed
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
