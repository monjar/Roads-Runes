import Foundation

/// What you carry (0.7.2), for previews, the mock and tests: the fifteen items of
/// `backend/app/inventory/config/gear.json`, a bag, the stall and the fifty levels.
public extension SampleData {
    /// The fifteen items as the catalogue has them: id, name, slot, rarity, icon, text.
    static let gearCatalog: [(itemId: String, name: String, slot: String, rarity: String, icon: String, text: String)] = [
        ("tin-bell", "Tin Bell", "BELL", "COMMON", "tinBell", "Creatures show up from 500 m away."),
        ("drovers-bell", "Drover's Bell", "BELL", "RARE", "droversBell", "Your opening blow on a creature is 25% stronger."),
        ("unrung-bell", "The Unrung Bell", "BELL", "LEGENDARY", "unrungBell",
         "A creature left with less than a tenth of its health is defeated."),
        ("candle-stub", "Candle Stub", "LANTERN", "COMMON", "candleStub", "One more ring of tiles explored around each new tile."),
        ("bullseye-lantern", "Bull's-eye Lantern", "LANTERN", "RARE", "bullseyeLantern", "Map pieces reveal half as much again."),
        ("wreckers-light", "Wrecker's Light", "LANTERN", "LEGENDARY", "wreckersLight", "Chests open when your journey passes within 150 m."),
        ("saddle-roll", "Saddle Roll", "BAG", "COMMON", "saddleRoll", "10% more coins for distance."),
        ("tinkers-satchel", "Tinker's Satchel", "BAG", "RARE", "tinkersSatchel", "20% more coins from chests, and items sell for more."),
        ("poachers-pocket", "Poacher's Pocket", "BAG", "LEGENDARY", "poachersPocket", "Better finds: items drop more often and rarer."),
        ("folded-map", "Folded Map", "MAP_CASE", "COMMON", "foldedMap", "One more quest on the quest board."),
        ("pedlars-roadbook", "Pedlar's Road-book", "MAP_CASE", "RARE", "pedlarsRoadbook", "Optional quest goals give double XP."),
        ("cartographers-atlas", "Cartographer's Atlas", "MAP_CASE", "LEGENDARY", "cartographersAtlas", "Each new tile counts 1.25 for exploring."),
        ("hagstone", "Hagstone", "KEEPSAKE", "COMMON", "hagstone", "Rune shapes are matched as kindly as a Wizard's."),
        ("rowan-twig", "Rowan Twig", "KEEPSAKE", "RARE", "rowanTwig", "A rune shape reaches creatures up to 1.5 km away."),
        ("runesmiths-nail", "Runesmith's Nail", "KEEPSAKE", "LEGENDARY", "runesmithsNail", "A woken rune counts one more rank."),
    ]

    /// What an item sells for, before the Tinker's Satchel.
    static func sellPrice(rarity: String) -> Int {
        switch rarity.uppercased() {
        case ItemRarity.legendary: return 400
        case ItemRarity.rare: return 120
        default: return 40
        }
    }

    /// One held copy of a catalogue item.
    static func gearItem(_ itemId: String, id: UUID = UUID(), equipped: Bool = false, source: String = "MONSTER") -> GearItem {
        let entry = gearCatalog.first { $0.itemId == itemId } ?? gearCatalog[0]
        return GearItem(id: id, itemId: entry.itemId, name: entry.name, slot: entry.slot, rarity: entry.rarity, icon: entry.icon,
                        text: entry.text, sellPrice: sellPrice(rarity: entry.rarity), equipped: equipped, acquiredAt: referenceDate,
                        source: source)
    }

    /// The five consumables: name, icon, what it does.
    static let consumableCatalog: [(id: String, name: String, icon: String, text: String)] = [
        ("LAMP", "Lamp", "lantern", "Light it at a place on the map and a creature comes. Used before coins."),
        ("MAP_FRAGMENT", "Map piece", "treasureMap", "Reveals the tiles round the nearest hidden place within 5 km."),
        ("REST_TOKEN", "Rest token", "restToken", "Keeps your streak going over one missed day. Used by itself."),
        ("SEALED_CHEST_COMMON", "Sealed chest", "chest", "Holds a Common item. Open it when your journey is over."),
        ("SEALED_CHEST_RARE", "Sealed chest (Rare)", "chest", "Holds a Rare item. Open it when your journey is over."),
    ]

    static func consumables(_ counts: [String: Int]) -> [ConsumableStack] {
        consumableCatalog.map { ConsumableStack(id: $0.id, name: $0.name, icon: $0.icon, text: $0.text, count: counts[$0.id] ?? 0) }
    }

    static let tinBellId = UUID(uuidString: "c0ffee00-0000-4000-8000-0000000000b1")!
    static let candleStubId = UUID(uuidString: "c0ffee00-0000-4000-8000-0000000000b2")!
    static let droversBellId = UUID(uuidString: "c0ffee00-0000-4000-8000-0000000000b3")!
    static let foldedMapId = UUID(uuidString: "c0ffee00-0000-4000-8000-0000000000b4")!

    /// The slots for a character at `level`, with what is worn in them.
    static func gearSlots(level: Int, worn: [String: GearItem] = [:]) -> [GearSlot] {
        GearSlotId.all.map { slot in
            let opens = GearSlotId.opensAtLevel[slot] ?? 1
            return GearSlot(slot: slot, name: GearSlotId.name(slot), opensAtLevel: opens, open: level >= opens, item: worn[slot])
        }
    }

    /// Level 8: a Tin Bell worn; a Candle Stub, a Drover's Bell and a Folded Map in the bag.
    static let sampleInventory = InventoryState(
        slots: gearSlots(level: 8, worn: ["BELL": gearItem("tin-bell", id: tinBellId, equipped: true, source: "LEVEL")]),
        bag: [
            gearItem("candle-stub", id: candleStubId, source: "CHEST"),
            gearItem("drovers-bell", id: droversBellId),
            gearItem("folded-map", id: foldedMapId, source: "QUEST"),
        ],
        bagSize: InventoryState.defaultBagSize,
        consumables: consumables(["LAMP": 2, "MAP_FRAGMENT": 1, "REST_TOKEN": 1, "SEALED_CHEST_COMMON": 1]),
        finishesSinceRare: 2
    )

    /// What the levels below 8 gave, paid on the first call after 0.7.2.
    static let sampleLevelRewardsPaid: [LevelReward] = Array(sampleLevelSteps.prefix(8).flatMap(\.rewards))

    /// Every level 1–50, as `progression/levels.py` lays it out: gear slots at 1, 3, 5,
    /// 13 and 21, rune slots at 1, 10 and 25, the stall at 3, a title where there is
    /// one, and otherwise a consumable in turn; every tenth level a Rare sealed chest too.
    static let sampleLevelSteps: [LevelStep] = (1...50).map { level in
        var rewards: [LevelReward] = []
        if let slot = GearSlotId.opensAtLevel.first(where: { $0.value == level })?.key {
            let icons = ["BELL": "tinBell", "LANTERN": "bullseyeLantern", "BAG": "tinkersSatchel", "MAP_CASE": "foldedMap", "KEEPSAKE": "hagstone"]
            rewards.append(LevelReward(kind: "SLOT", text: "\(GearSlotId.name(slot)) slot opens", icon: icons[slot]))
        }
        if [1, 10, 25].contains(level) { rewards.append(LevelReward(kind: "RUNE_SLOT", text: "A rune slot opens", icon: "runeStone")) }
        if level == 3 { rewards.append(LevelReward(kind: "STALL", text: "The stall opens", icon: "shop")) }
        if let title = [1: "Passer-by", 5: "Familiar Face", 10: "Roadwise", 20: "Old Hand", 30: "Waymaker", 40: "Long Road", 50: "Road-sworn"][level] {
            rewards.append(LevelReward(kind: "TITLE", text: "Title: \(title)", icon: "laurels"))
        }
        if rewards.isEmpty {
            let turn = ConsumableId.all.filter { $0 != ConsumableId.sealedChestRare }
            let pick = turn[(level - 2) % turn.count]
            let entry = consumableCatalog.first { $0.id == pick }
            let count = pick == ConsumableId.lamp ? 2 : 1
            let text = count == 1 ? "A \(entry?.name.lowercased() ?? "find")" : "\(count) \(entry?.name.lowercased() ?? "find")s"
            rewards.append(LevelReward(kind: "CONSUMABLE", text: text, icon: entry?.icon, consumable: pick, count: count))
        }
        if level % 10 == 0 {
            rewards.append(LevelReward(kind: "CONSUMABLE", text: "A sealed chest (Rare)", icon: "chest",
                                       consumable: ConsumableId.sealedChestRare, count: 1))
        }
        return LevelStep(level: level, reached: level <= 8, rewards: rewards)
    }

    /// This week's four: two gear, two consumables.
    static let sampleStall = Stall(
        open: true, opensAtLevel: 3, week: "2026-W41", resetsAt: referenceDate.addingTimeInterval(4 * 86_400),
        offers: [
            StallOffer(id: "w41-0", kind: "GEAR", itemId: "saddle-roll", name: "Saddle Roll", rarity: "COMMON", icon: "saddleRoll", slot: "BAG",
                       text: "10% more coins for distance.", price: 150),
            StallOffer(id: "w41-1", kind: "GEAR", itemId: "rowan-twig", name: "Rowan Twig", rarity: "RARE", icon: "rowanTwig", slot: "KEEPSAKE",
                       text: "A rune shape reaches creatures up to 1.5 km away.", price: 450),
            StallOffer(id: "w41-2", kind: "CONSUMABLE", consumable: "LAMP", name: "Lamp", icon: "lantern",
                       text: "Light it at a place on the map and a creature comes.", price: 40),
            StallOffer(id: "w41-3", kind: "CONSUMABLE", consumable: "MAP_FRAGMENT", name: "Map piece", icon: "treasureMap",
                       text: "Reveals the tiles round the nearest hidden place.", price: 60),
        ]
    )

    /// A journey's finds: a Rare from a creature, a lamp from a chest, and one sold because the bag was full.
    static let sampleItemsFound: [ItemFound] = [
        ItemFound(kind: "GEAR", inventoryItemId: UUID(uuidString: "c0ffee00-0000-4000-8000-0000000000c1"), itemId: "tinkers-satchel",
                  name: "Tinker's Satchel", icon: "tinkersSatchel", rarity: "RARE", slot: "BAG", source: "MONSTER", fromName: "Fen Troll"),
        ItemFound(kind: "CONSUMABLE", consumable: "LAMP", name: "Lamp", icon: "lantern", source: "CHEST", fromName: "Old chest"),
        ItemFound(kind: "GEAR", itemId: "hagstone", name: "Hagstone", icon: "hagstone", rarity: "COMMON", slot: "KEEPSAKE", source: "CHEST",
                  fromName: "Iron chest", soldOnTheSpot: true, soldFor: 40),
    ]
}
