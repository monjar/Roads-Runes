import XCTest
@testable import RoadsAndRunesCore

/// The mock keeps the server's rules for what you carry (0.7.2), so previews and
/// the app's tests meet the same refusals the server gives.
final class MockAPIInventoryTests: XCTestCase {
    private func code(of call: () async throws -> some Any) async -> String? {
        do {
            _ = try await call()
            return nil
        } catch let error as APIError {
            return error.errorCode
        } catch {
            return "OTHER"
        }
    }

    func testTheFirstLookPaysTheLevelsReachedOnce() async throws {
        let api = MockAPI()
        let first = try await api.inventory()
        XCTAssertFalse(first.levelRewardsPaid?.isEmpty ?? true, "level 8 has rewards to pay")
        XCTAssertTrue(first.levelRewardsPaid?.contains { $0.kind == "STALL" } ?? false)
        let second = try await api.inventory()
        XCTAssertNil(second.levelRewardsPaid, "paid once")
        XCTAssertEqual(first.slots.filter(\.open).map(\.slot), ["BELL", "LANTERN", "BAG"], "level 8 opens three slots")
    }

    func testWearingSwapsWhatIsWornIntoTheBag() async throws {
        let api = MockAPI()
        let worn = try await api.wearGear(GearChoice(slot: "BELL", itemId: SampleData.droversBellId))
        XCTAssertEqual(worn.slots.first { $0.slot == "BELL" }?.item?.itemId, "drovers-bell")
        XCTAssertTrue(worn.bag.contains { $0.itemId == "tin-bell" && !$0.equipped }, "the old bell goes back in the bag")
        XCTAssertFalse(worn.bag.contains { $0.id == SampleData.droversBellId })

        let off = try await api.wearGear(GearChoice(slot: "BELL", itemId: nil))
        XCTAssertNil(off.slots.first { $0.slot == "BELL" }?.item)

        let wrong = await code { try await api.wearGear(GearChoice(slot: "LANTERN", itemId: SampleData.droversBellId)) }
        XCTAssertEqual(wrong, APIErrorCode.wrongSlot)
        let locked = await code { try await api.wearGear(GearChoice(slot: "MAP_CASE", itemId: SampleData.foldedMapId)) }
        XCTAssertEqual(locked, APIErrorCode.slotLocked)

        // Not while a journey is being recorded.
        _ = try await api.createRide(RideCreate(clientRideId: UUID(), startedAt: Date()))
        let riding = await code { try await api.wearGear(GearChoice(slot: "LANTERN", itemId: SampleData.candleStubId)) }
        XCTAssertEqual(riding, APIErrorCode.loadoutLocked)
    }

    func testSellingPaysAndWhatIsWornMustComeOffFirst() async throws {
        let api = MockAPI()
        let refused = await code { try await api.sellItem(id: SampleData.tinBellId) }
        XCTAssertEqual(refused, APIErrorCode.takeOffFirst)
        let sold = try await api.sellItem(id: SampleData.droversBellId)
        XCTAssertEqual(sold.soldFor, 120)
        XCTAssertEqual(sold.walletBalance, 120)
        XCTAssertFalse(sold.inventory?.bag.contains { $0.id == SampleData.droversBellId } ?? true)
        let ledger = try await api.walletTransactions(limit: nil, cursor: nil)
        XCTAssertEqual(ledger.items.first?.kind, .itemSold)
    }

    func testAMapPieceFindsTheNearestHiddenPlaceAndASealedChestHoldsAnItem() async throws {
        let api = MockAPI()
        let piece = try await api.useConsumable(id: ConsumableId.mapPiece, ConsumableUseRequest(at: SampleData.origin))
        XCTAssertEqual(piece.placeName, "The Crown", "the place not yet found")
        XCTAssertEqual(piece.inventory?.count(of: ConsumableId.mapPiece), 0)
        let none = await code { try await api.useConsumable(id: ConsumableId.mapPiece, ConsumableUseRequest(at: SampleData.origin)) }
        XCTAssertEqual(none, APIErrorCode.noneLeft)

        let chest = try await api.useConsumable(id: ConsumableId.sealedChestCommon, ConsumableUseRequest())
        XCTAssertEqual(chest.itemFound?.rarity, ItemRarity.common)
        XCTAssertEqual(chest.inventory?.bag.count, 4)

        let far = MockAPI()
        let nowhere = await code { try await far.useConsumable(id: ConsumableId.mapPiece, ConsumableUseRequest(latitude: 10, longitude: 10)) }
        XCTAssertEqual(nowhere, APIErrorCode.noHiddenPlace)
        let kept = try await far.inventory()
        XCTAssertEqual(kept.count(of: ConsumableId.mapPiece), 1, "nothing is used when there is no hidden place")
    }

    func testASealedChestWaitsUntilTheJourneyIsOver() async throws {
        let api = MockAPI()
        _ = try await api.createRide(RideCreate(clientRideId: UUID(), startedAt: Date()))
        let later = await code { try await api.useConsumable(id: ConsumableId.sealedChestCommon, ConsumableUseRequest()) }
        XCTAssertEqual(later, APIErrorCode.openLater)
    }

    func testAFullBagSellsTheFindOnTheSpot() async throws {
        let api = MockAPI()
        api.storedInventory.bag = (0..<20).map { _ in SampleData.gearItem("hagstone") }
        let chest = try await api.useConsumable(id: ConsumableId.sealedChestCommon, ConsumableUseRequest())
        XCTAssertEqual(chest.itemFound?.soldOnTheSpot, true)
        XCTAssertEqual(chest.itemFound?.soldFor, 40)
        XCTAssertEqual(chest.inventory?.bag.count, 20)
    }

    func testTheStallSellsOnceAWeekAndOpensAtLevelThree() async throws {
        let api = MockAPI()
        let stall = try await api.stall()
        XCTAssertTrue(stall.open)
        XCTAssertEqual(stall.offers.count, 4)
        let poor = await code { try await api.buyOffer(id: "w41-2") }
        XCTAssertEqual(poor, APIErrorCode.insufficientCoins)
        api.storedCoins = 100
        let bought = try await api.buyOffer(id: "w41-2")
        XCTAssertEqual(bought.count(of: ConsumableId.lamp), 3)
        let twice = await code { try await api.buyOffer(id: "w41-2") }
        XCTAssertEqual(twice, APIErrorCode.alreadyBought)
        let after = try await api.stall()
        XCTAssertEqual(after.offers.first { $0.id == "w41-2" }?.bought, true)

        let young = MockAPI()
        young.storedCharacter?.overallLevel = 2
        let closed = try await young.stall()
        XCTAssertFalse(closed.open)
        let refused = await code { try await young.buyOffer(id: "w41-0") }
        XCTAssertEqual(refused, APIErrorCode.stallClosed)
    }

    func testEveryLevelGivesSomething() async throws {
        let levels = try await MockAPI().levelRewards()
        XCTAssertEqual(levels.map(\.level), Array(1...50))
        XCTAssertTrue(levels.allSatisfy { !$0.rewards.isEmpty })
        XCTAssertEqual(levels.filter(\.reached).count, 8)
        XCTAssertTrue(levels[9].rewards.contains { $0.consumable == ConsumableId.sealedChestRare }, "every tenth level a Rare sealed chest")
    }

    func testALampFromTheBagIsUsedBeforeCoins() async throws {
        let api = MockAPI()
        let check = try await api.lampCheck(at: SampleData.origin)
        XCTAssertEqual(check.cost, 0)
        XCTAssertEqual(check.lampsInBag, 2)
        _ = try await api.lure(at: SampleData.origin)
        _ = try await api.lure(at: SampleData.origin)
        let empty = try await api.lampCheck(at: SampleData.origin)
        XCTAssertEqual(empty.lampsInBag, 0)
        XCTAssertEqual(empty.cost, 50)
        let poor = await code { try await api.lure(at: SampleData.origin) }
        XCTAssertEqual(poor, APIErrorCode.insufficientCoins)
    }

    func testAChestOpenedByHandSaysWhatItHeld() async throws {
        let api = MockAPI()
        let claim = try await api.claimWorldObject(id: SampleData.sampleChest.id, WorldObjectClaimRequest(
            latitude: SampleData.sampleChest.latitude, longitude: SampleData.sampleChest.longitude))
        XCTAssertEqual(claim.itemFound?.consumable, ConsumableId.lamp)
    }

    func testTheSummaryAndTheJournalCarryWhatIsNew() async throws {
        let api = MockAPI()
        api.summaryPollsBeforeReady = 0
        let summary = try await api.rideSummary(id: SampleData.rideId)
        XCTAssertEqual(summary?.itemsFound?.count, 3)
        XCTAssertEqual(summary?.streak?.restTokenUsed, true)
        XCTAssertFalse(summary?.levelUps.first?.rewards?.isEmpty ?? true)
        let journal = try await api.adventures()
        XCTAssertNotNil(journal.items.first?.entryWritten)
    }

    func testOfflineEveryCallFailsAsTheNetworkDoes() async {
        let api = MockAPI()
        api.offline = true
        do {
            _ = try await api.worldObjects(near: SampleData.origin, radiusMeters: 1000)
            XCTFail("offline")
        } catch let error as APIError {
            guard case .network = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTheNewEndpointsGoWhereTheContractSays() throws {
        XCTAssertEqual(Endpoints.inventory().path, "/inventory")
        let wear = try Endpoints.wearGear(GearChoice(slot: "BELL", itemId: nil))
        XCTAssertEqual(wear.method, .put)
        XCTAssertEqual(wear.path, "/inventory/gear")
        XCTAssertEqual(Endpoints.sellItem(id: SampleData.tinBellId).path, "/inventory/items/\(SampleData.tinBellId.uuidString)/sell")
        let use = try Endpoints.useConsumable(id: "MAP_FRAGMENT", ConsumableUseRequest(latitude: 51.5, longitude: -0.1))
        XCTAssertEqual(use.path, "/inventory/consumables/MAP_FRAGMENT/use")
        XCTAssertEqual(use.method, .post)
        XCTAssertEqual(Endpoints.stall().path, "/inventory/stall")
        XCTAssertEqual(Endpoints.buyOffer(id: "w41-0").path, "/inventory/stall/w41-0/buy")
        XCTAssertEqual(Endpoints.levelRewards().path, "/inventory/levels")
    }
}
