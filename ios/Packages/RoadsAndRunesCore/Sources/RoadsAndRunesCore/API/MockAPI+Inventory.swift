import Foundation

// What you carry (0.7.2): the server's rules for gear, the bag, consumables and
// the stall, small enough to hold in memory. Called inside `run`, so under the lock.
extension MockAPI {
    // MARK: Helpers

    func conflict(_ code: String, _ message: String) -> APIError {
        .server(code: code, message: message, status: 409)
    }

    var characterLevel: Int { storedCharacter?.overallLevel ?? 1 }

    /// A ride is being recorded: the loadout is locked and sealed chests wait.
    var isRecording: Bool { storedRides.values.contains { $0.status == .recording } }

    /// Takes one of a consumable from the bag; false when there is none.
    func takeConsumable(_ id: String) -> Bool {
        guard let index = storedInventory.consumables.firstIndex(where: { $0.id == id }), storedInventory.consumables[index].count >= 1 else {
            return false
        }
        storedInventory.consumables[index].count -= 1
        return true
    }

    func give(_ consumable: String, count: Int) {
        if let index = storedInventory.consumables.firstIndex(where: { $0.id == consumable }) {
            storedInventory.consumables[index].count += count
        } else if let entry = SampleData.consumableCatalog.first(where: { $0.id == consumable }) {
            storedInventory.consumables.append(ConsumableStack(id: entry.id, name: entry.name, icon: entry.icon, text: entry.text, count: count))
        }
    }

    /// Into the bag, or sold on the spot when it is full, as the server does it.
    func receive(_ item: GearItem, source: String) -> ItemFound {
        var found = ItemFound(kind: "GEAR", inventoryItemId: item.id, itemId: item.itemId, name: item.name, icon: item.icon, rarity: item.rarity,
                              slot: item.slot, source: source)
        if storedInventory.bagIsFull {
            let price = item.sellPrice ?? SampleData.sellPrice(rarity: item.rarity)
            storedCoins += price
            storedTransactions.insert(WalletTransaction(id: UUID(), amount: price, kind: .itemSold, createdAt: Date()), at: 0)
            found.soldOnTheSpot = true
            found.soldFor = price
            found.inventoryItemId = nil
        } else {
            storedInventory.bag.append(item)
        }
        return found
    }

    /// The slots as the character's level has opened them, keeping what is worn.
    func refreshSlots() {
        let worn = Dictionary(uniqueKeysWithValues: storedInventory.slots.compactMap { slot in slot.item.map { (slot.slot, $0) } })
        storedInventory.slots = SampleData.gearSlots(level: characterLevel, worn: worn)
    }

    // MARK: Endpoints

    public func inventory() async throws -> InventoryState {
        try await run {
            _ = try self.requireCharacter()
            self.refreshSlots()
            var out = self.storedInventory
            if self.levelRewardsUnpaid {
                self.levelRewardsUnpaid = false
                out.levelRewardsPaid = SampleData.sampleLevelSteps.filter { $0.level <= self.characterLevel }.flatMap(\.rewards)
            }
            return out
        }
    }

    public func wearGear(_ choice: GearChoice) async throws -> InventoryState {
        try await run {
            self.refreshSlots()
            guard let index = self.storedInventory.slots.firstIndex(where: { $0.slot == choice.slot }) else { throw self.notFound("Slot") }
            let slot = self.storedInventory.slots[index]
            guard slot.open else { throw self.conflict(APIErrorCode.slotLocked, "That slot opens at level \(slot.opensAtLevel).") }
            if self.isRecording {
                throw self.conflict(APIErrorCode.loadoutLocked, "Change your gear when your journey is over.")
            }
            var incoming: GearItem?
            if let itemId = choice.itemId {
                guard let bagIndex = self.storedInventory.bag.firstIndex(where: { $0.id == itemId }) else { throw self.notFound("Item") }
                guard self.storedInventory.bag[bagIndex].slot == choice.slot else {
                    throw self.conflict(APIErrorCode.wrongSlot, "That goes in another slot.")
                }
                incoming = self.storedInventory.bag.remove(at: bagIndex)
                incoming?.equipped = true
            }
            if var outgoing = slot.item {
                outgoing.equipped = false
                self.storedInventory.bag.append(outgoing)
            }
            self.storedInventory.slots[index].item = incoming
            return self.storedInventory
        }
    }

    public func sellItem(id: UUID) async throws -> SellResult {
        try await run {
            if self.storedInventory.worn.contains(where: { $0.id == id }) {
                throw self.conflict(APIErrorCode.takeOffFirst, "Take it off before you sell it.")
            }
            guard let index = self.storedInventory.bag.firstIndex(where: { $0.id == id }) else { throw self.notFound("Item") }
            let item = self.storedInventory.bag.remove(at: index)
            let price = item.sellPrice ?? SampleData.sellPrice(rarity: item.rarity)
            self.storedCoins += price
            self.storedTransactions.insert(WalletTransaction(id: UUID(), amount: price, kind: .itemSold, createdAt: Date()), at: 0)
            return SellResult(soldFor: price, walletBalance: self.storedCoins, inventory: self.storedInventory)
        }
    }

    public func useConsumable(id: String, _ request: ConsumableUseRequest) async throws -> ConsumableUseResult {
        try await run {
            let none = self.conflict(APIErrorCode.noneLeft, "You don't have any of those. Find them on journeys or at the stall.")
            guard self.storedInventory.count(of: id) > 0 else { throw none }
            switch id {
            case ConsumableId.mapPiece:
                // The nearest place the player has not found, within 5 km of where they stand.
                guard let latitude = request.latitude, let longitude = request.longitude else {
                    throw APIError.server(code: APIErrorCode.validationError, message: "Where are you? Try again once your location is found.", status: 422)
                }
                let here = Coordinate(latitude: latitude, longitude: longitude)
                let hidden = self.storedDiscoveries.values
                    .filter { !$0.discoveredByUser && GeoMath.distance(here, $0.coordinate) <= 5000 }
                    .min { GeoMath.distance(here, $0.coordinate) < GeoMath.distance(here, $1.coordinate) }
                guard let place = hidden else {
                    throw self.conflict(APIErrorCode.noHiddenPlace, "No hidden places near here. Try it somewhere new.")
                }
                _ = self.takeConsumable(id)
                return ConsumableUseResult(revealedTiles: 7, placeName: place.name, latitude: place.latitude, longitude: place.longitude,
                                           inventory: self.storedInventory)
            case ConsumableId.treasureMap:
                return try self.useTreasureMap(request)
            case ConsumableId.sealedChestCommon, ConsumableId.sealedChestRare:
                if self.isRecording { throw self.conflict(APIErrorCode.openLater, "Open it when your journey is over.") }
                _ = self.takeConsumable(id)
                let rarity = id == ConsumableId.sealedChestRare ? ItemRarity.rare : ItemRarity.common
                let pick = SampleData.gearCatalog.filter { $0.rarity == rarity }
                let entry = pick[self.storedInventory.bag.count % pick.count]
                let item = SampleData.gearItem(entry.itemId, source: "SEALED_CHEST")
                let found = self.receive(item, source: "SEALED_CHEST")
                return ConsumableUseResult(itemFound: found, item: found.soldOnTheSpot ? nil : item, inventory: self.storedInventory)
            default:
                // A lamp is lit at a place; a rest token uses itself.
                throw none
            }
        }
    }

    public func stall() async throws -> Stall {
        try await run {
            var stall = SampleData.sampleStall
            stall.open = self.characterLevel >= stall.opensAtLevel
            if !stall.open { stall.offers = [] }
            for index in stall.offers.indices { stall.offers[index].bought = self.stallBought.contains(stall.offers[index].id) }
            return stall
        }
    }

    public func buyOffer(id: String) async throws -> InventoryState {
        try await run {
            let stall = SampleData.sampleStall
            guard self.characterLevel >= stall.opensAtLevel else {
                throw self.conflict(APIErrorCode.stallClosed, "The stall opens at level \(stall.opensAtLevel).")
            }
            guard let offer = stall.offers.first(where: { $0.id == id }) else { throw self.notFound("Offer") }
            guard !self.stallBought.contains(id) else {
                throw self.conflict(APIErrorCode.alreadyBought, "You've bought that one this week. New things come on Monday.")
            }
            guard self.storedCoins >= offer.price else {
                throw self.conflict(APIErrorCode.insufficientCoins, "That costs \(offer.price) coins and you have \(self.storedCoins).")
            }
            self.storedCoins -= offer.price
            self.storedTransactions.insert(WalletTransaction(id: UUID(), amount: -offer.price, kind: .stall, createdAt: Date()), at: 0)
            self.stallBought.insert(id)
            if offer.isCosmetic, let itemId = offer.itemId {
                // A look (0.9.0): owned, not worn, and never in the bag.
                var owned = self.storedInventory.cosmetics ?? []
                if !owned.contains(where: { $0.itemId == itemId }) {
                    owned.append(Cosmetic(itemId: itemId, name: CosmeticCatalog.name(itemId), color: offer.color, source: "STALL"))
                }
                self.storedInventory.cosmetics = owned
            } else if let itemId = offer.itemId {
                _ = self.receive(SampleData.gearItem(itemId, source: "STALL"), source: "STALL")
            } else if let consumable = offer.consumable {
                self.give(consumable, count: 1)
            }
            return self.storedInventory
        }
    }

    public func levelRewards() async throws -> [LevelStep] {
        try await run {
            let level = self.characterLevel
            return SampleData.sampleLevelSteps.map { step in
                var step = step
                step.reached = step.level <= level
                return step
            }
        }
    }
}
