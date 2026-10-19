import Foundation

/// The kinds of way a quest can be ridden (`GET /quests/{id}/ways`): a loop home,
/// one way out, the long way, new ground, quiet roads. Unknown kinds decode safely.
public enum QuestWayKind: String, SafeEnum {
    case loop = "LOOP"
    case oneWay = "ONE_WAY"
    case longWay = "LONG_WAY"
    case newGround = "NEW_GROUND"
    case quiet = "QUIET"
    case unknown = "UNKNOWN"

    /// What the server calls it, for where only the route (not its way) is to hand.
    public var displayName: String? {
        switch self {
        case .loop: "Loop"
        case .oneWay: "One way"
        case .longWay: "The long way"
        case .newGround: "New ground"
        case .quiet: "Quiet roads"
        case .unknown: nil
        }
    }
}

/// What a way pays on top of the quest, and what it asks for it.
public struct QuestWayBonus: Codable, Hashable, Sendable {
    public var xp: Int
    public var ac: Int
    public var condition: String

    public init(xp: Int, ac: Int, condition: String) {
        self.xp = xp
        self.ac = ac
        self.condition = condition
    }
}

/// One way to ride a quest: its kind, the server's name and line for it, and its route.
public struct QuestWay: Codable, Hashable, Identifiable, Sendable {
    public var kind: QuestWayKind
    public var name: String
    public var summary: String
    public var bonus: QuestWayBonus?
    public var route: RouteOption

    public var id: UUID { route.id }

    public init(kind: QuestWayKind, name: String, summary: String, bonus: QuestWayBonus? = nil, route: RouteOption) {
        self.kind = kind
        self.name = name
        self.summary = summary
        self.bonus = bonus
        self.route = route
    }
}

/// `GET /quests/{id}/ways`: the ways in display order (the loop first), the one the
/// quest has now, and short notes on any way that is not offered.
public struct QuestWays: Codable, Hashable, Sendable {
    public var ways: [QuestWay]
    public var chosenRouteId: UUID?
    public var notes: [String]

    public init(ways: [QuestWay], chosenRouteId: UUID? = nil, notes: [String] = []) {
        self.ways = ways
        self.chosenRouteId = chosenRouteId
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ways = try container.decodeIfPresent([QuestWay].self, forKey: .ways) ?? []
        chosenRouteId = try container.decodeIfPresent(UUID.self, forKey: .chosenRouteId)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

/// `POST /quests/{id}/way`.
public struct QuestWayChoice: Codable, Hashable, Sendable {
    public var routeId: UUID

    public init(routeId: UUID) { self.routeId = routeId }
}
