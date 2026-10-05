import Foundation

// What you carry (0.7.2): gear in five slots, a bag, consumables, the stall, and
// what each level gives. Every type here is new with 0.7.2; the fields an older
// type gained for it are optional on that type, so an older server still decodes.

/// Item rarity, as the server spells it. Kept a string on the wire: an unknown
/// rarity must not stop the bag from opening.
public enum ItemRarity {
    public static let common = "COMMON"
    public static let rare = "RARE"
    public static let legendary = "LEGENDARY"

    /// "Common", "Rare", "Legendary".
    public static func name(_ rarity: String?) -> String? {
        guard let rarity, !rarity.isEmpty else { return nil }
        return rarity.prefix(1).uppercased() + rarity.dropFirst().lowercased()
    }
}

/// The five slots, by their code ids (`BELL` … `KEEPSAKE`), and the level each opens at.
public enum GearSlotId {
    public static let bell = "BELL"
    public static let lantern = "LANTERN"
    public static let bag = "BAG"
    public static let mapCase = "MAP_CASE"
    public static let keepsake = "KEEPSAKE"
    public static let all = [bell, lantern, bag, mapCase, keepsake]
    public static let opensAtLevel: [String: Int] = [bell: 1, lantern: 3, bag: 5, mapCase: 13, keepsake: 21]

    /// "Map case", for a slot the server did not name.
    public static func name(_ slot: String) -> String {
        let words = slot.lowercased().split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// The consumables, by id.
public enum ConsumableId {
    public static let lamp = "LAMP"
    public static let mapPiece = "MAP_FRAGMENT"
    public static let restToken = "REST_TOKEN"
    public static let sealedChestCommon = "SEALED_CHEST_COMMON"
    public static let sealedChestRare = "SEALED_CHEST_RARE"
    /// 0.8.0: used where you stand, it buries a treasure and gives its clue.
    public static let treasureMap = "TREASURE_MAP"
    public static let all = [lamp, mapPiece, restToken, sealedChestCommon, sealedChestRare, treasureMap]

    /// The ones used from the bag by hand; a lamp is lit at a place, a rest token uses itself.
    public static func usableFromTheBag(_ id: String) -> Bool {
        id == mapPiece || id == sealedChestCommon || id == sealedChestRare || id == treasureMap
    }

    /// Used where the player stands, so they need a location first.
    public static func needsLocation(_ id: String) -> Bool {
        id == mapPiece || id == treasureMap
    }
}

/// One item of gear the player holds (`GearItemOut`): worn or in the bag.
public struct GearItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The catalogue id ("tin-bell").
    public var itemId: String
    public var name: String
    public var slot: String
    public var rarity: String
    /// The `GameIcon` raw name to draw.
    public var icon: String?
    /// What it does, in one plain sentence.
    public var text: String
    public var sellPrice: Int?
    public var equipped: Bool
    public var acquiredAt: Date?
    /// MONSTER, CHEST, QUEST, BOUNTY, STALL, LEVEL, SEALED_CHEST.
    public var source: String?

    public init(id: UUID, itemId: String, name: String, slot: String, rarity: String, icon: String? = nil, text: String,
                sellPrice: Int? = nil, equipped: Bool = false, acquiredAt: Date? = nil, source: String? = nil) {
        self.id = id
        self.itemId = itemId
        self.name = name
        self.slot = slot
        self.rarity = rarity
        self.icon = icon
        self.text = text
        self.sellPrice = sellPrice
        self.equipped = equipped
        self.acquiredAt = acquiredAt
        self.source = source
    }
}

/// One of the five slots: whether the level has opened it, and what is worn there.
public struct GearSlot: Codable, Hashable, Identifiable, Sendable {
    public var slot: String
    public var name: String
    public var opensAtLevel: Int
    public var open: Bool
    public var item: GearItem?

    public var id: String { slot }

    public init(slot: String, name: String, opensAtLevel: Int, open: Bool, item: GearItem? = nil) {
        self.slot = slot
        self.name = name
        self.opensAtLevel = opensAtLevel
        self.open = open
        self.item = item
    }
}

/// How many of one consumable the player holds (always all five, a count may be 0).
public struct ConsumableStack: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var icon: String?
    public var text: String
    public var count: Int

    public init(id: String, name: String, icon: String? = nil, text: String, count: Int) {
        self.id = id
        self.name = name
        self.icon = icon
        self.text = text
        self.count = count
    }
}

/// One thing a level gives (`LevelRewardOut`): a slot, a rune slot, the stall, a
/// title or some consumables. "Lantern slot opens", "2 lamps".
public struct LevelReward: Codable, Hashable, Sendable {
    /// SLOT, RUNE_SLOT, STALL, TITLE or CONSUMABLE.
    public var kind: String
    public var text: String
    public var icon: String?
    public var consumable: String?
    public var count: Int?

    public init(kind: String, text: String, icon: String? = nil, consumable: String? = nil, count: Int? = nil) {
        self.kind = kind
        self.text = text
        self.icon = icon
        self.consumable = consumable
        self.count = count
    }
}

/// `GET /inventory/levels`: one row per level, 1 to 50.
public struct LevelStep: Codable, Hashable, Identifiable, Sendable {
    public var level: Int
    public var reached: Bool
    public var rewards: [LevelReward]

    public var id: Int { level }

    public init(level: Int, reached: Bool, rewards: [LevelReward]) {
        self.level = level
        self.reached = reached
        self.rewards = rewards
    }
}

/// `GET /inventory` (`InventoryOut`): the slots, the bag, the consumables, and
/// once — on the call that paid them — what the levels already reached gave.
public struct InventoryState: Codable, Hashable, Sendable {
    public var slots: [GearSlot]
    public var bag: [GearItem]
    public var bagSize: Int
    public var consumables: [ConsumableStack]
    public var finishesSinceRare: Int?
    /// Non-empty once: on the first call after 0.7.2, for every level already reached.
    public var levelRewardsPaid: [LevelReward]?

    public static let defaultBagSize = 20

    public init(slots: [GearSlot], bag: [GearItem] = [], bagSize: Int = Self.defaultBagSize, consumables: [ConsumableStack] = [],
                finishesSinceRare: Int? = nil, levelRewardsPaid: [LevelReward]? = nil) {
        self.slots = slots
        self.bag = bag
        self.bagSize = bagSize
        self.consumables = consumables
        self.finishesSinceRare = finishesSinceRare
        self.levelRewardsPaid = levelRewardsPaid
    }

    private enum CodingKeys: String, CodingKey {
        case slots, bag, bagSize, consumables, finishesSinceRare, levelRewardsPaid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decode([GearSlot].self, forKey: .slots)
        bag = try c.decodeIfPresent([GearItem].self, forKey: .bag) ?? []
        bagSize = try c.decodeIfPresent(Int.self, forKey: .bagSize) ?? Self.defaultBagSize
        consumables = try c.decodeIfPresent([ConsumableStack].self, forKey: .consumables) ?? []
        finishesSinceRare = try c.decodeIfPresent(Int.self, forKey: .finishesSinceRare)
        levelRewardsPaid = try c.decodeIfPresent([LevelReward].self, forKey: .levelRewardsPaid)
    }

    /// Twenty unequipped items: the next find is sold on the spot.
    public var bagIsFull: Bool { bag.count >= bagSize }

    /// What is worn, anywhere.
    public var worn: [GearItem] { slots.compactMap(\.item) }

    /// The items in the bag that go in this slot, rarest first.
    public func bagItems(for slot: String) -> [GearItem] {
        bag.filter { $0.slot == slot }.sorted { (Self.rank($0.rarity), $0.name) > (Self.rank($1.rarity), $1.name) }
    }

    public func count(of consumable: String) -> Int {
        consumables.first { $0.id == consumable }?.count ?? 0
    }

    static func rank(_ rarity: String) -> Int {
        switch rarity.uppercased() {
        case ItemRarity.legendary: return 2
        case ItemRarity.rare: return 1
        default: return 0
        }
    }
}

/// `PUT /inventory/gear`: wear an item in a slot, or `nil` to take it off.
public struct GearChoice: Codable, Hashable, Sendable {
    public var slot: String
    public var itemId: UUID?

    public init(slot: String, itemId: UUID?) {
        self.slot = slot
        self.itemId = itemId
    }

    // `{"itemId": null}` means take it off; it must be sent, not dropped.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slot, forKey: .slot)
        try c.encode(itemId, forKey: .itemId)
    }
}

/// `POST /inventory/consumables/{id}/use`: where the player is (a map piece looks
/// for the nearest hidden place from here).
public struct ConsumableUseRequest: Codable, Hashable, Sendable {
    public var latitude: Double?
    public var longitude: Double?

    public init(latitude: Double? = nil, longitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(at coordinate: Coordinate?) {
        self.init(latitude: coordinate?.latitude, longitude: coordinate?.longitude)
    }
}

/// What a consumable did: a map piece revealed tiles round a hidden place, a
/// sealed chest held an item. The inventory after, when the server sends it.
public struct ConsumableUseResult: Codable, Hashable, Sendable {
    public var revealedTiles: Int?
    public var placeName: String?
    public var latitude: Double?
    public var longitude: Double?
    /// What a sealed chest held.
    public var itemFound: ItemFound?
    public var item: GearItem?
    public var inventory: InventoryState?
    /// A treasure map (0.8.0): the clue to where it buried the treasure. Never a place.
    public var clue: String?
    public var treasureId: UUID?

    public init(revealedTiles: Int? = nil, placeName: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                itemFound: ItemFound? = nil, item: GearItem? = nil, inventory: InventoryState? = nil, clue: String? = nil,
                treasureId: UUID? = nil) {
        self.clue = clue
        self.treasureId = treasureId
        self.revealedTiles = revealedTiles
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.itemFound = itemFound
        self.item = item
        self.inventory = inventory
    }

    private enum CodingKeys: String, CodingKey {
        case revealedTiles, placeName, latitude, longitude, itemFound, item, inventory, clue, treasureId
    }

    /// The inventory may come under `inventory` or be the whole answer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clue = try c.decodeIfPresent(String.self, forKey: .clue)
        treasureId = try? c.decodeIfPresent(UUID.self, forKey: .treasureId)
        revealedTiles = try c.decodeIfPresent(Int.self, forKey: .revealedTiles)
        placeName = try c.decodeIfPresent(String.self, forKey: .placeName)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        itemFound = try c.decodeIfPresent(ItemFound.self, forKey: .itemFound)
        item = try c.decodeIfPresent(GearItem.self, forKey: .item)
        inventory = try c.decodeIfPresent(InventoryState.self, forKey: .inventory) ?? (try? InventoryState(from: decoder))
    }

    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    /// The treasure map's clue as an open clue, for the Quests tab.
    public var treasureClue: TreasureClue? {
        guard let clue, !clue.isEmpty else { return nil }
        return TreasureClue(treasureId: treasureId, clue: clue)
    }
}

/// `POST /inventory/items/{id}/sell`: the coins, the purse after, the inventory after.
public struct SellResult: Codable, Hashable, Sendable {
    public var soldFor: Int?
    public var walletBalance: Int?
    public var inventory: InventoryState?

    public init(soldFor: Int? = nil, walletBalance: Int? = nil, inventory: InventoryState? = nil) {
        self.soldFor = soldFor
        self.walletBalance = walletBalance
        self.inventory = inventory
    }

    private enum CodingKeys: String, CodingKey {
        case soldFor, walletBalance, inventory
    }

    /// The inventory may come under `inventory` or be the whole answer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        soldFor = try c.decodeIfPresent(Int.self, forKey: .soldFor)
        walletBalance = try c.decodeIfPresent(Int.self, forKey: .walletBalance)
        inventory = try c.decodeIfPresent(InventoryState.self, forKey: .inventory) ?? (try? InventoryState(from: decoder))
    }
}

/// One of the four things on the stall this week (`StallOffer`).
public struct StallOffer: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// GEAR or CONSUMABLE.
    public var kind: String
    public var itemId: String?
    public var consumable: String?
    public var name: String
    public var rarity: String?
    public var icon: String?
    public var slot: String?
    public var text: String
    public var price: Int
    public var bought: Bool

    public init(id: String, kind: String, itemId: String? = nil, consumable: String? = nil, name: String, rarity: String? = nil,
                icon: String? = nil, slot: String? = nil, text: String, price: Int, bought: Bool = false) {
        self.id = id
        self.kind = kind
        self.itemId = itemId
        self.consumable = consumable
        self.name = name
        self.rarity = rarity
        self.icon = icon
        self.slot = slot
        self.text = text
        self.price = price
        self.bought = bought
    }

    public var isGear: Bool { kind == "GEAR" }
}

/// `GET /inventory/stall`: four offers an ISO week, open from level 3.
public struct Stall: Codable, Hashable, Sendable {
    public var open: Bool
    public var opensAtLevel: Int
    public var week: String?
    public var resetsAt: Date?
    public var offers: [StallOffer]

    public init(open: Bool, opensAtLevel: Int = 3, week: String? = nil, resetsAt: Date? = nil, offers: [StallOffer] = []) {
        self.open = open
        self.opensAtLevel = opensAtLevel
        self.week = week
        self.resetsAt = resetsAt
        self.offers = offers
    }

    private enum CodingKeys: String, CodingKey {
        case open, opensAtLevel, week, resetsAt, offers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = try c.decode(Bool.self, forKey: .open)
        opensAtLevel = try c.decodeIfPresent(Int.self, forKey: .opensAtLevel) ?? 3
        week = try c.decodeIfPresent(String.self, forKey: .week)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        offers = try c.decodeIfPresent([StallOffer].self, forKey: .offers) ?? []
    }
}

/// Something found on a journey or opened at a standstill (`ItemFoundOut`): gear
/// or a consumable, where it came from, and whether a full bag sold it at once.
public struct ItemFound: Codable, Hashable, Sendable {
    /// GEAR or CONSUMABLE.
    public var kind: String
    public var inventoryItemId: UUID?
    public var itemId: String?
    public var consumable: String?
    public var name: String
    /// The `GameIcon` raw name to draw.
    public var icon: String?
    public var rarity: String?
    public var slot: String?
    /// MONSTER, CHEST, QUEST or BOUNTY.
    public var source: String?
    /// What it came from: "Fen Troll".
    public var fromName: String?
    /// The bag was full, so it was sold where it was found.
    public var soldOnTheSpot: Bool
    public var soldFor: Int?

    public init(kind: String, inventoryItemId: UUID? = nil, itemId: String? = nil, consumable: String? = nil, name: String,
                icon: String? = nil, rarity: String? = nil, slot: String? = nil, source: String? = nil, fromName: String? = nil,
                soldOnTheSpot: Bool = false, soldFor: Int? = nil) {
        self.kind = kind
        self.inventoryItemId = inventoryItemId
        self.itemId = itemId
        self.consumable = consumable
        self.name = name
        self.icon = icon
        self.rarity = rarity
        self.slot = slot
        self.source = source
        self.fromName = fromName
        self.soldOnTheSpot = soldOnTheSpot
        self.soldFor = soldFor
    }

    private enum CodingKeys: String, CodingKey {
        case kind, inventoryItemId, itemId, consumable, name, icon, rarity, slot, source, fromName, soldOnTheSpot, soldFor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "GEAR"
        inventoryItemId = try c.decodeIfPresent(UUID.self, forKey: .inventoryItemId)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
        consumable = try c.decodeIfPresent(String.self, forKey: .consumable)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        rarity = try c.decodeIfPresent(String.self, forKey: .rarity)
        slot = try c.decodeIfPresent(String.self, forKey: .slot)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        fromName = try c.decodeIfPresent(String.self, forKey: .fromName)
        soldOnTheSpot = try c.decodeIfPresent(Bool.self, forKey: .soldOnTheSpot) ?? false
        soldFor = try c.decodeIfPresent(Int.self, forKey: .soldFor)
    }

    public var isGear: Bool { kind == "GEAR" }
}

/// An item a quest gives when it is done (`rewards.items[]`, 0.7.2).
public struct QuestRewardItem: Codable, Hashable, Sendable {
    public var itemId: String
    public var name: String
    public var rarity: String?
    public var icon: String?
    public var slot: String?

    public init(itemId: String, name: String, rarity: String? = nil, icon: String? = nil, slot: String? = nil) {
        self.itemId = itemId
        self.name = name
        self.rarity = rarity
        self.icon = icon
        self.slot = slot
    }

    /// As it travels inside the quest's loosely typed `items` array.
    public var json: JSONValue {
        var object: [String: JSONValue] = ["itemId": .string(itemId), "name": .string(name)]
        if let rarity { object["rarity"] = .string(rarity) }
        if let icon { object["icon"] = .string(icon) }
        if let slot { object["slot"] = .string(slot) }
        return .object(object)
    }

    /// One entry of `items`; nil for anything that is not an item.
    public init?(json: JSONValue) {
        guard let object = json.objectValue, let itemId = object["itemId"]?.stringValue, let name = object["name"]?.stringValue else {
            return nil
        }
        self.init(itemId: itemId, name: name, rarity: object["rarity"]?.stringValue, icon: object["icon"]?.stringValue,
                  slot: object["slot"]?.stringValue)
    }
}

public extension QuestRewards {
    /// The items the quest gives, read from its `items` (empty before 0.7.2).
    var rewardItems: [QuestRewardItem] { (items ?? []).compactMap(QuestRewardItem.init(json:)) }
}

/// A creature's variant (0.7.2): Stubborn, Skittish or Mossy.
public struct CreatureVariant: Codable, Hashable, Sendable {
    /// STUBBORN, SKITTISH or MOSSY.
    public var id: String
    /// "Stubborn".
    public var name: String
    /// "30% more health and 30% more coins."
    public var text: String?

    public init(id: String, name: String, text: String? = nil) {
        self.id = id
        self.name = name
        self.text = text
    }
}

/// A creature back for a second go (0.7.2): "Fen Troll the Grumpy".
public struct CreatureGrudge: Codable, Hashable, Sendable {
    public var epithet: String
    /// "It got away twice. Now it's back, and grumpier."
    public var line: String?

    public init(epithet: String, line: String? = nil) {
        self.epithet = epithet
        self.line = line
    }
}

/// What a creature leaves behind, counted on its Codex page (0.7.2): no storage,
/// just the leavings and how many were defeated.
public struct CreatureTrophies: Codable, Hashable, Sendable {
    /// "a green scale".
    public var name: String
    public var count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }

    /// "Left behind: a green scale ×3".
    public var line: String { "Left behind: \(name) ×\(count)" }
}

/// The model-written entry (0.7.2, `chronicle_llm`): lines written after the
/// journey, by the model, from categories only. The composed `entry` stays.
public struct EntryWritten: Codable, Hashable, Sendable {
    public var lines: [String]
    /// "model".
    public var by: String?

    public init(lines: [String], by: String? = nil) {
        self.lines = lines
        self.by = by
    }

    public var text: String { lines.joined(separator: " ") }
}
