import Foundation

/// `GET /wallet`: Active Coins, the currency spent on the character where XP is kept.
public struct Wallet: Codable, Hashable, Sendable {
    public var balance: Int
    public var lifetimeEarned: Int

    public init(balance: Int, lifetimeEarned: Int) {
        self.balance = balance
        self.lifetimeEarned = lifetimeEarned
    }
}

public enum WalletTransactionKind: String, SafeEnum {
    case rideDistance = "RIDE_DISTANCE"
    case newCells = "NEW_CELLS"
    case questCompleted = "QUEST_COMPLETED"
    case chestOpened = "CHEST_OPENED"
    case collectable = "COLLECTABLE"
    case monsterSlain = "MONSTER_SLAIN"
    case bounty = "BOUNTY"
    case streak = "STREAK"
    case classChange = "CLASS_CHANGE"
    case lure = "LURE"
    case adjustment = "ADJUSTMENT"
    case setCompleted = "SET_COMPLETED"
    case storyArc = "STORY_ARC"
    case weekNotice = "WEEK_NOTICE"
    case runeRank = "RUNE_RANK"
    /// 0.7.2: bought at the stall, an item sold, a level's reward.
    case stall = "STALL"
    case itemSold = "ITEM_SOLD"
    case levelReward = "LEVEL_REWARD"
    /// 0.9.0: a district completed, and the week's pay for the districts that are yours.
    case district = "DISTRICT"
    case districtPay = "DISTRICT_PAY"
    case unknown = "UNKNOWN"

    /// The line in coin history, in plain words (docs/VOICE.md).
    public var label: String {
        switch self {
        case .rideDistance: return "Distance"
        case .newCells: return "New tiles"
        case .questCompleted: return "Quest reward"
        case .chestOpened: return "Chest opened"
        case .collectable: return "Piece picked up"
        case .monsterSlain: return "Creature defeated"
        case .bounty: return "Bounty"
        case .streak: return "Streak bonus"
        case .classChange: return "Class change"
        case .lure: return "Lamp lit"
        case .adjustment: return "Adjustment"
        case .setCompleted: return "Set complete"
        case .storyArc: return "Story arc finished"
        case .weekNotice: return "This week's notice"
        case .runeRank: return "Rune ranked up"
        case .stall: return "Bought at the stall"
        case .itemSold: return "Item sold"
        case .levelReward: return "Level reward"
        case .district: return "District complete"
        case .districtPay: return "Weekly pay from your districts"
        case .unknown: return "Coins"
        }
    }
}

/// One line of the coin ledger. `amount` is signed: earned above zero, spent below.
public struct WalletTransaction: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var amount: Int
    public var kind: WalletTransactionKind
    public var rideId: UUID?
    public var questId: UUID?
    public var objectId: UUID?
    public var payload: [String: JSONValue]?
    public var createdAt: Date

    public init(id: UUID, amount: Int, kind: WalletTransactionKind, rideId: UUID? = nil, questId: UUID? = nil, objectId: UUID? = nil, payload: [String: JSONValue]? = nil, createdAt: Date) {
        self.id = id
        self.amount = amount
        self.kind = kind
        self.rideId = rideId
        self.questId = questId
        self.objectId = objectId
        self.payload = payload
        self.createdAt = createdAt
    }
}

/// One line of a ride's coin breakdown, mirroring `XPBreakdownEntry`.
public struct ACBreakdownEntry: Codable, Hashable, Sendable {
    public var kind: String
    public var ac: Int
    public var detail: JSONValue?

    public init(kind: String, ac: Int, detail: JSONValue? = nil) {
        self.kind = kind
        self.ac = ac
        self.detail = detail
    }
}
