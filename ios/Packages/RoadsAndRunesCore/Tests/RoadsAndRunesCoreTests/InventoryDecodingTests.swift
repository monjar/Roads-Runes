import XCTest
@testable import RoadsAndRunesCore

/// What you carry (0.7.2), as the contract's payloads have it, and every new
/// field on an older type read from a server that never sent it.
final class InventoryDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.makeDecoder().decode(type, from: Data(json.utf8))
    }

    static let inventoryJSON = #"""
    {
      "slots": [
        {"slot": "BELL", "name": "Bell", "opensAtLevel": 1, "open": true,
         "item": {"id": "c0ffee00-0000-4000-8000-0000000000b1", "itemId": "tin-bell", "name": "Tin Bell", "slot": "BELL",
                  "rarity": "COMMON", "icon": "tinBell", "text": "Creatures show up from 500 m away.", "sellPrice": 40,
                  "equipped": true, "acquiredAt": "2026-10-04T09:00:00+00:00", "source": "LEVEL"}},
        {"slot": "LANTERN", "name": "Lantern", "opensAtLevel": 3, "open": true, "item": null},
        {"slot": "BAG", "name": "Bag", "opensAtLevel": 5, "open": true},
        {"slot": "MAP_CASE", "name": "Map case", "opensAtLevel": 13, "open": false},
        {"slot": "KEEPSAKE", "name": "Keepsake", "opensAtLevel": 21, "open": false}
      ],
      "bag": [
        {"id": "c0ffee00-0000-4000-8000-0000000000b3", "itemId": "drovers-bell", "name": "Drover's Bell", "slot": "BELL",
         "rarity": "RARE", "icon": "droversBell", "text": "Your opening blow on a creature is 25% stronger.", "sellPrice": 120,
         "equipped": false, "acquiredAt": "2026-10-04T09:30:00.120000Z", "source": "MONSTER"}
      ],
      "bagSize": 20,
      "consumables": [
        {"id": "LAMP", "name": "Lamp", "icon": "lantern", "text": "A free lamp.", "count": 2},
        {"id": "MAP_FRAGMENT", "name": "Map piece", "icon": "treasureMap", "text": "Reveals a hidden place.", "count": 0},
        {"id": "REST_TOKEN", "name": "Rest token", "icon": "restToken", "text": "Keeps a streak.", "count": 1},
        {"id": "SEALED_CHEST_COMMON", "name": "Sealed chest", "icon": "chest", "text": "A Common item.", "count": 0},
        {"id": "SEALED_CHEST_RARE", "name": "Sealed chest (Rare)", "icon": "chest", "text": "A Rare item.", "count": 0}
      ],
      "finishesSinceRare": 3,
      "levelRewardsPaid": [
        {"kind": "SLOT", "text": "Lantern slot opens", "icon": "bullseyeLantern"},
        {"kind": "STALL", "text": "The stall opens", "icon": "shop"},
        {"kind": "CONSUMABLE", "text": "2 lamps", "icon": "lantern", "consumable": "LAMP", "count": 2}
      ]
    }
    """#

    func testTheInventoryDecodes() throws {
        let inventory = try decode(InventoryState.self, Self.inventoryJSON)
        XCTAssertEqual(inventory.slots.map(\.slot), GearSlotId.all)
        XCTAssertEqual(inventory.slots.first?.item?.name, "Tin Bell")
        XCTAssertNil(inventory.slots[1].item)
        XCTAssertFalse(inventory.slots[3].open)
        XCTAssertEqual(inventory.worn.map(\.itemId), ["tin-bell"])
        XCTAssertEqual(inventory.bagItems(for: "BELL").map(\.itemId), ["drovers-bell"])
        XCTAssertEqual(inventory.count(of: ConsumableId.lamp), 2)
        XCTAssertEqual(inventory.count(of: "NOT_A_THING"), 0)
        XCTAssertEqual(inventory.levelRewardsPaid?.map(\.kind), ["SLOT", "STALL", "CONSUMABLE"])
        XCTAssertEqual(inventory.levelRewardsPaid?.last?.count, 2)
        XCTAssertFalse(inventory.bagIsFull)
        XCTAssertNotNil(inventory.bag.first?.acquiredAt, "fractional seconds and offsets both read")
    }

    /// A lean answer (an empty bag left out, no bag size, no rewards) still opens the bag.
    func testALeanInventoryDecodesWithDefaults() throws {
        let lean = try decode(InventoryState.self, #"{"slots": [{"slot": "BELL", "name": "Bell", "opensAtLevel": 1, "open": true}]}"#)
        XCTAssertEqual(lean.bagSize, 20)
        XCTAssertTrue(lean.bag.isEmpty)
        XCTAssertNil(lean.levelRewardsPaid)
        var full = lean
        full.bag = (0..<20).map { _ in SampleData.gearItem("hagstone") }
        XCTAssertTrue(full.bagIsFull)
    }

    func testTakingGearOffSendsANull() throws {
        let off = try XCTUnwrap(String(data: JSONCoding.encode(GearChoice(slot: "BELL", itemId: nil)), encoding: .utf8))
        XCTAssertTrue(off.contains(#""itemId":null"#), off)
        let on = try JSONCoding.makeDecoder().decode(GearChoice.self, from: JSONCoding.encode(GearChoice(slot: "BELL", itemId: SampleData.tinBellId)))
        XCTAssertEqual(on.itemId, SampleData.tinBellId)
    }

    func testTheStallAndTheLevelsDecode() throws {
        let stall = try decode(Stall.self, #"""
        {"open": true, "opensAtLevel": 3, "week": "2026-W41", "resetsAt": "2026-10-12T00:00:00+00:00",
         "offers": [
           {"id": "w41-0", "kind": "GEAR", "itemId": "saddle-roll", "name": "Saddle Roll", "rarity": "COMMON", "icon": "saddleRoll",
            "slot": "BAG", "text": "10% more coins for distance.", "price": 150, "bought": false},
           {"id": "w41-2", "kind": "CONSUMABLE", "consumable": "LAMP", "name": "Lamp", "icon": "lantern", "text": "A free lamp.",
            "price": 40, "bought": true}
         ]}
        """#)
        XCTAssertEqual(stall.offers.count, 2)
        XCTAssertTrue(stall.offers[0].isGear)
        XCTAssertTrue(stall.offers[1].bought)
        XCTAssertNotNil(stall.resetsAt)
        let closed = try decode(Stall.self, #"{"open": false}"#)
        XCTAssertEqual(closed.opensAtLevel, 3)
        XCTAssertTrue(closed.offers.isEmpty)

        let levels = try decode([LevelStep].self, #"""
        [{"level": 1, "reached": true, "rewards": [{"kind": "SLOT", "text": "Bell slot opens", "icon": "tinBell"},
                                                     {"kind": "TITLE", "text": "Title: Passer-by", "icon": "laurels"}]},
         {"level": 2, "reached": false, "rewards": [{"kind": "CONSUMABLE", "text": "2 lamps", "consumable": "LAMP", "count": 2}]}]
        """#)
        XCTAssertEqual(levels.map(\.level), [1, 2])
        XCTAssertEqual(levels[0].rewards.count, 2)
        XCTAssertNil(levels[1].rewards[0].icon)
    }

    /// A sale, a map piece and a sealed chest: the inventory under `inventory` or as the whole answer.
    func testWhatSellingAndUsingSayDecodes() throws {
        let nested = try decode(SellResult.self, #"{"soldFor": 120, "walletBalance": 400, "inventory": \#(Self.inventoryJSON)}"#)
        XCTAssertEqual(nested.soldFor, 120)
        XCTAssertEqual(nested.inventory?.slots.count, 5)
        let bare = try decode(SellResult.self, Self.inventoryJSON)
        XCTAssertNil(bare.soldFor)
        XCTAssertEqual(bare.inventory?.bag.count, 1)

        let piece = try decode(ConsumableUseResult.self, #"""
        {"revealedTiles": 19, "placeName": "The Crown", "latitude": 51.49, "longitude": -0.03, "inventory": \#(Self.inventoryJSON)}
        """#)
        XCTAssertEqual(piece.revealedTiles, 19)
        XCTAssertEqual(piece.coordinate, Coordinate(latitude: 51.49, longitude: -0.03))
        let chest = try decode(ConsumableUseResult.self, #"""
        {"itemFound": {"kind": "GEAR", "itemId": "rowan-twig", "name": "Rowan Twig", "icon": "rowanTwig", "rarity": "RARE",
                       "slot": "KEEPSAKE", "source": "SEALED_CHEST", "soldOnTheSpot": false}}
        """#)
        XCTAssertEqual(chest.itemFound?.name, "Rowan Twig")
        XCTAssertNil(chest.inventory)
    }

    /// The ride summary's 0.7.2 parts: finds, a rest token, what a level gave, the model's entry.
    func testTheSummaryCarriesWhatWasFound() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AdventureSummaryDecodingTests.json.utf8)) as? [String: Any])
        json["itemsFound"] = [
            ["kind": "GEAR", "inventoryItemId": "c0ffee00-0000-4000-8000-0000000000c1", "itemId": "tinkers-satchel", "name": "Tinker's Satchel",
             "icon": "tinkersSatchel", "rarity": "RARE", "slot": "BAG", "source": "MONSTER", "fromName": "Fen Troll", "soldOnTheSpot": false],
            ["kind": "GEAR", "itemId": "hagstone", "name": "Hagstone", "icon": "hagstone", "rarity": "COMMON", "slot": "KEEPSAKE",
             "source": "CHEST", "soldOnTheSpot": true, "soldFor": 40],
            ["kind": "CONSUMABLE", "consumable": "LAMP", "name": "Lamp", "icon": "lantern", "source": "CHEST", "soldOnTheSpot": false],
        ]
        json["streak"] = ["days": 5, "longest": 9, "extended": true, "milestone": NSNull(), "bonusAC": 0, "restTokenUsed": true]
        json["levelUps"] = [["kind": "OVERALL", "from": 2, "to": 3, "rewards": [["kind": "STALL", "text": "The stall opens", "icon": "shop"]]]]
        json["entryWritten"] = ["lines": ["You went the long way round.", "The troll never woke."], "by": "model"]
        json["entry"] = "Composed."
        let summary = try JSONCoding.makeDecoder().decode(AdventureSummary.self, from: JSONSerialization.data(withJSONObject: json))
        let found = try XCTUnwrap(summary.itemsFound)
        XCTAssertEqual(found.map(\.name), ["Tinker's Satchel", "Hagstone", "Lamp"])
        XCTAssertEqual(found[0].fromName, "Fen Troll")
        XCTAssertTrue(found[1].soldOnTheSpot)
        XCTAssertEqual(found[1].soldFor, 40)
        XCTAssertFalse(found[2].isGear)
        XCTAssertEqual(summary.streak?.restTokenUsed, true)
        XCTAssertEqual(summary.levelUps.first?.rewards?.first?.text, "The stall opens")
        XCTAssertEqual(summary.entryToRead, "You went the long way round. The troll never woke.")
    }

    /// The same summary from a 0.7.1 server: nothing new, nothing broken.
    func testAnOlderServersSummaryStillDecodes() throws {
        let summary = try decode(AdventureSummary.self, AdventureSummaryDecodingTests.json)
        XCTAssertNil(summary.itemsFound)
        XCTAssertNil(summary.entryWritten)
        XCTAssertNil(summary.streak?.restTokenUsed)
        XCTAssertTrue(summary.levelUps.allSatisfy { $0.rewards == nil })
        XCTAssertEqual(summary.entryToRead, summary.entry)

        let lamp = try decode(LampCheck.self, #"{"ok": true, "cost": 50, "placeName": "the towpath"}"#)
        XCTAssertNil(lamp.lampsInBag)
        XCTAssertFalse(lamp.usesLampFromBag)
        let free = try decode(LampCheck.self, #"{"ok": true, "cost": 0, "placeName": "the towpath", "lampsInBag": 2}"#)
        XCTAssertTrue(free.usesLampFromBag)

        let streak = try decode(StreakOutcome.self, #"{"days": 3, "longest": 3, "extended": true, "bonusAC": 0}"#)
        XCTAssertNil(streak.restTokenUsed)
    }

    func testATappedChestSaysWhatItHeld() throws {
        let object = #"""
        {"id": "8a1f0b2c-0000-4000-8000-00000000a002", "kind": "CHEST", "status": "CLAIMED", "tier": 1, "latitude": 51.4881,
         "longitude": -0.0202, "name": "Old chest", "rewardAC": 25, "expiresAt": "2026-10-07T00:00:00+00:00"}
        """#
        let claim = try decode(WorldObjectClaim.self, #"""
        {"object": \#(object), "acAwarded": 25, "walletBalance": 200, "xpAwarded": 10, "levelUps": [],
         "itemFound": {"kind": "GEAR", "itemId": "candle-stub", "name": "Candle Stub", "icon": "candleStub", "rarity": "COMMON",
                       "slot": "LANTERN", "source": "CHEST", "soldOnTheSpot": false}}
        """#)
        XCTAssertEqual(claim.itemFound?.name, "Candle Stub")
        let old = try decode(WorldObjectClaim.self, #"{"object": \#(object), "acAwarded": 25, "walletBalance": 200}"#)
        XCTAssertNil(old.itemFound)
        let none = try decode(WorldObjectClaim.self, #"{"object": \#(object), "acAwarded": 25, "walletBalance": 200, "itemFound": null}"#)
        XCTAssertNil(none.itemFound)
    }

    func testAVariantAndAGrudgeAreRead() throws {
        let stubborn = try decode(WorldObject.self, #"""
        {"id": "8a1f0b2c-0000-4000-8000-00000000a011", "kind": "MONSTER", "status": "SPAWNED", "tier": 1, "latitude": 51.49,
         "longitude": -0.03, "name": "Fen Troll", "rewardAC": 78, "expiresAt": "2026-10-07T00:00:00+00:00",
         "monster": {"hp": 130, "killMethods": [], "speciesId": "fen-troll", "sigil": {"body": "hulk", "feature": "horns", "mark": "water", "icon": "troll"},
                     "variant": {"id": "STUBBORN", "name": "Stubborn", "text": "30% more health and 30% more coins."},
                     "displayName": "Stubborn Fen Troll"}}
        """#)
        XCTAssertEqual(stubborn.monster?.variant?.id, "STUBBORN")
        XCTAssertEqual(stubborn.monster?.sigil?.icon, "troll")
        XCTAssertEqual(stubborn.name, "Fen Troll")
        XCTAssertEqual(stubborn.shownName, "Stubborn Fen Troll")

        // Without a display name the client puts the variant first, once.
        var skittish = stubborn
        skittish.monster?.displayName = nil
        skittish.monster?.variant = CreatureVariant(id: "SKITTISH", name: "Skittish")
        XCTAssertEqual(skittish.shownName, "Skittish Fen Troll")

        let grudge = try decode(MonsterInfo.self, #"""
        {"hp": 500, "killMethods": [], "grudge": {"epithet": "Grumpy", "line": "It got away twice. Now it's back, and grumpier."}}
        """#)
        XCTAssertEqual(grudge.grudge?.epithet, "Grumpy")
        XCTAssertNil(grudge.variant)

        let plain = try decode(MonsterInfo.self, #"{"hp": 100, "killMethods": [], "sigil": {"body": "wisp", "feature": "hood", "mark": "reeds"}}"#)
        XCTAssertNil(plain.variant)
        XCTAssertNil(plain.grudge)
        XCTAssertNil(plain.sigil?.icon)
    }

    func testTheCodexCountsWhatWasLeftBehind() throws {
        let creature = #"""
        {"id": "hedge-dragon", "name": "Hedge Dragon", "family": "GREEN", "flavour": "Warm.", "hint": "Parks.", "page": "A page.",
         "leaves": "a green scale", "wants": ["GROUND", "RUNE"], "minds": ["WORD"], "rune": "raido",
         "elders": [{"tier": 2, "name": "Thicket Dragon", "flavour": "", "seen": false}],
         "sigil": {"body": "wyrm", "feature": "wings", "mark": "tree", "icon": "hedgeDragon"},
         "state": "MET", "seenCount": 4, "seenOffCount": 3
        """#
        let now = try decode(CodexCreature.self, creature + #", "trophies": {"name": "a green scale", "count": 3}}"#)
        XCTAssertEqual(now.trophies?.line, "Left behind: a green scale ×3")
        XCTAssertEqual(now.sigil.icon, "hedgeDragon")
        let before = try decode(CodexCreature.self, creature + "}")
        XCTAssertNil(before.trophies)
    }

    func testAQuestNamesTheItemItGives() throws {
        let rewards = try decode(QuestRewards.self, #"""
        {"xp": 600, "ac": 200, "items": [{"itemId": "pedlars-roadbook", "name": "Pedlar's Road-book", "rarity": "RARE",
                                          "icon": "pedlarsRoadbook", "slot": "MAP_CASE"}, "not an item"], "titles": []}
        """#)
        XCTAssertEqual(rewards.rewardItems, [QuestRewardItem(itemId: "pedlars-roadbook", name: "Pedlar's Road-book", rarity: "RARE",
                                                              icon: "pedlarsRoadbook", slot: "MAP_CASE")])
        let none = try decode(QuestRewards.self, #"{"xp": 100, "items": [], "titles": []}"#)
        XCTAssertTrue(none.rewardItems.isEmpty)
        let item = QuestRewardItem(itemId: "hagstone", name: "Hagstone", rarity: "COMMON")
        XCTAssertEqual(QuestRewardItem(json: item.json), item)
    }

    func testTheJournalReadsTheModelsEntryFirst() throws {
        var entry = AdventureEntry(ride: SampleData.sampleRide, xpAwarded: 10, discoveries: [], newTerritoryMeters: 0, entry: "Composed.")
        XCTAssertEqual(entry.entryToRead, "Composed.")
        entry.entryWritten = EntryWritten(lines: ["One.", "Two."], by: "model")
        XCTAssertEqual(entry.entryToRead, "One. Two.")
        entry.entryWritten = EntryWritten(lines: [])
        XCTAssertEqual(entry.entryToRead, "Composed.", "an empty written entry falls back")
        let ride = try decode(Ride.self, #"""
        {"id": "7afb0d83-be8a-43ae-b218-f789cb5058f1", "clientRideId": "86d96b8c-4a93-4928-a27a-0e00969de8d5", "status": "PROCESSED",
         "startedAt": "2026-09-11T18:25:28Z", "distanceMeters": 100, "durationSeconds": 60, "movingSeconds": 60, "elevationGainMeters": 0,
         "visibility": "PRIVATE", "pointCount": 2, "createdAt": "2026-09-11T18:25:28Z",
         "entryWritten": {"lines": ["Out by the water."], "by": "model"}}
        """#)
        XCTAssertEqual(ride.entryWritten?.text, "Out by the water.")
    }

    func testTheSheetCarriesTheGearAndTheRules() throws {
        let sheet = try decode(CharacterSheet.self, #"""
        {"version": 4, "characterClass": "EXPLORER", "overallLevel": 22, "classLevel": 9, "damagePct": {"GROUND": 0.3},
         "runeThreshold": 0.3, "runeReachMeters": 1500, "rules": {"SIGHT_M": 500, "FINISH_UNDER": 0.1, "GROUND_CELL_SCALE": 1.25,
         "CARRIED_SCALE": 1.25}, "gear": {"BELL": "unrung-bell", "MAP_CASE": "cartographers-atlas"}, "lootFindPct": 0.1}
        """#)
        XCTAssertEqual(sheet.gear?["BELL"], "unrung-bell")
        XCTAssertEqual(sheet.lootFindPct, 0.1)
        XCTAssertEqual(sheet.sightMeters, 500)
        let cfg = sheet.fightConstants(CombatConstants())
        XCTAssertEqual(cfg.finishUnder, 0.1)
        XCTAssertEqual(cfg.groundCellScale, 1.25)
        XCTAssertEqual(cfg.carriedFraction, 0.25, accuracy: 1e-9)

        let older = try decode(CharacterSheet.self, #"""
        {"version": 3, "characterClass": "WIZARD", "overallLevel": 4, "classLevel": 4, "damagePct": {}, "runeThreshold": 0.3,
         "runeReachMeters": 1000, "rules": {"REVEAL_RINGS": 1}}
        """#)
        XCTAssertNil(older.gear)
        XCTAssertEqual(older.sightMeters, 600, "Kenaz alone, as before")
        XCTAssertEqual(older.fightConstants(CombatConstants()).finishUnder, 0)
        var both = older
        both.rules?["SIGHT_M"] = 500
        XCTAssertEqual(both.sightMeters, 600, "the larger of Kenaz and the bell")
    }

    func testTheNewCoinKindsHavePlainLabels() throws {
        let line = try decode(WalletTransaction.self, #"""
        {"id": "7afb0d83-be8a-43ae-b218-f789cb5058f1", "amount": -150, "kind": "STALL", "createdAt": "2026-10-04T10:00:00Z"}
        """#)
        XCTAssertEqual(line.kind, .stall)
        XCTAssertEqual(line.kind.label, "Bought at the stall")
        XCTAssertEqual(WalletTransactionKind.itemSold.label, "Item sold")
        let unknown = try decode(WalletTransaction.self, #"""
        {"id": "7afb0d83-be8a-43ae-b218-f789cb5058f1", "amount": 5, "kind": "SOMETHING_NEW", "createdAt": "2026-10-04T10:00:00Z"}
        """#)
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(RewardCopy.coins(kind: "ITEM_SOLD"), "Sold on the spot")
    }

    func testRarityNamesReadPlainly() {
        XCTAssertEqual(ItemRarity.name("LEGENDARY"), "Legendary")
        XCTAssertNil(ItemRarity.name(nil))
        XCTAssertEqual(GearSlotId.name("MAP_CASE"), "Map case")
        XCTAssertTrue(ConsumableId.usableFromTheBag("MAP_FRAGMENT"))
        XCTAssertFalse(ConsumableId.usableFromTheBag("LAMP"))
    }
}
