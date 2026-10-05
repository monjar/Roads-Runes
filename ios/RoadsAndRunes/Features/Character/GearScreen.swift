import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// What the gear screens do, kept in one place: the bag lives on the session, so
/// the sheet, the slot and the item all see the same thing after a change.
@MainActor
@Observable
final class GearModel {
    var error: String?
    /// The item, slot or consumable being changed right now.
    private(set) var busy: String?
    /// A line about what just happened ("Map piece used: …"), for a few seconds.
    private(set) var notice: String?
    /// The server has no bag (one from before 0.7.2).
    private(set) var missing = false
    private(set) var loaded = false
    private let container: AppContainer
    private var noticeTask: Task<Void, Never>?

    init(container: AppContainer) { self.container = container }

    var inventory: InventoryState? { container.session.inventory }
    var level: Int { container.session.character?.overallLevel ?? 1 }

    func load() async {
        do {
            container.session.take(inventory: try await container.api.inventory())
            error = nil
        } catch let failure as APIError where failure.isNotFound {
            missing = true
        } catch {
            if inventory == nil { self.error = error.localizedDescription }
        }
        loaded = true
    }

    func wear(_ item: GearItem) async {
        await change(item.id.uuidString) { try await self.container.api.wearGear(GearChoice(slot: item.slot, itemId: item.id)) }
    }

    func takeOff(_ item: GearItem) async {
        await change(item.id.uuidString) { try await self.container.api.wearGear(GearChoice(slot: item.slot, itemId: nil)) }
    }

    func sell(_ item: GearItem) async {
        busy = item.id.uuidString
        defer { busy = nil }
        do {
            let result = try await container.api.sellItem(id: item.id)
            if let after = result.inventory { container.session.take(inventory: after) } else { await container.session.refreshInventory() }
            let coins = result.soldFor ?? item.sellPrice ?? 0
            show("Sold \(item.name): \(LoreCopy.earned(coins)).")
            error = nil
            await container.session.refreshCharacter()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A map piece or a sealed chest. A map piece looks round where the player is.
    func use(_ stack: ConsumableStack) async {
        let here = container.location.lastFix?.coordinate
        if stack.id == ConsumableId.mapPiece, here == nil {
            error = "Can't find your location yet. Try again in a moment."
            return
        }
        busy = stack.id
        defer { busy = nil }
        do {
            let result = try await container.api.useConsumable(id: stack.id, ConsumableUseRequest(at: here))
            if let after = result.inventory { container.session.take(inventory: after) } else { await container.session.refreshInventory() }
            show(Self.line(for: result, used: stack))
            error = nil
            if result.itemFound?.soldOnTheSpot == true { await container.session.refreshCharacter() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "Map piece used: 19 tiles revealed round The Crown." / "The sealed chest held a Rowan Twig (Rare)."
    static func line(for result: ConsumableUseResult, used stack: ConsumableStack) -> String {
        if let found = result.itemFound {
            let rarity = ItemRarity.name(found.rarity).map { " (\($0))" } ?? ""
            if found.soldOnTheSpot {
                return "The sealed chest held \(found.name)\(rarity). Your bag was full, so it was sold: \(LoreCopy.earned(found.soldFor ?? 0))."
            }
            return "The sealed chest held \(found.name)\(rarity). It's in your bag."
        }
        if let tiles = result.revealedTiles {
            let place = result.placeName.map { " round \($0)" } ?? ""
            return "Map piece used: \(tiles) \(tiles == 1 ? "tile" : "tiles") revealed\(place)."
        }
        return "\(stack.name) used."
    }

    private func change(_ id: String, _ call: @escaping () async throws -> InventoryState) async {
        busy = id
        defer { busy = nil }
        do {
            container.session.take(inventory: try await call())
            error = nil
            await container.session.refreshCharacter()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func show(_ line: String) {
        notice = line
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

/// Gear (0.7.2): the five slots and what is worn in them, the bag, and the lamps,
/// map pieces, rest tokens and sealed chests carried. Only worn gear works.
struct GearScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var model: GearModel?
    @State private var selected: GearItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let model {
                    content(model)
                } else {
                    ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("Gear")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = GearModel(container: container) }
            await model?.load()
        }
        .sheet(item: $selected) { item in
            if let model { ItemDetailSheet(itemId: item.id, model: model) }
        }
    }

    @ViewBuilder
    private func content(_ model: GearModel) -> some View {
        if model.missing {
            EmptyState(icon: .tinBell, title: "Gear isn't here yet", message: "It arrives with the next server update.")
        }
        if let error = model.error { ErrorLine(text: error) }
        if let notice = model.notice {
            NoticeLine(text: notice).accessibilityIdentifier("gear.notice")
        }
        if let inventory = model.inventory {
            slots(inventory, model: model)
            bag(inventory, model: model)
            consumables(inventory, model: model)
            SectionHeader(title: "More")
            NavigationLink { StallScreen() } label: { GearLinkRow(title: "The stall", icon: .shop) }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("gear.stall")
            NavigationLink { LevelsScreen() } label: { GearLinkRow(title: "What each level gives", icon: .levelUp) }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("gear.levels")
        } else if model.loaded, !model.missing, model.error == nil {
            EmptyState(icon: .tinBell, title: "No gear yet", message: "Defeat creatures and open chests to find gear.")
        }
    }

    private func slots(_ inventory: InventoryState, model: GearModel) -> some View {
        let open = inventory.slots.filter(\.open)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Worn", subtitle: "\(open.filter { $0.item != nil }.count) of \(open.count) slots")
            VStack(spacing: 8) {
                ForEach(inventory.slots) { slot in
                    NavigationLink { GearSlotScreen(slot: slot.slot, model: model) } label: { SlotRow(slot: slot, inBag: inventory.bagItems(for: slot.slot).count) }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("gear.slot.\(slot.slot)")
                }
            }
            Text("Only worn gear works. Change it any time you're not on a journey.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        }
    }

    @ViewBuilder
    private func bag(_ inventory: InventoryState, model: GearModel) -> some View {
        SectionHeader(title: "Your bag", subtitle: "\(inventory.bag.count) / \(inventory.bagSize)")
        if inventory.bagIsFull {
            Text("Your bag is full. Your next find will be sold on the spot. Sell something to make room.")
                .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("gear.bagFull")
        }
        if inventory.bag.isEmpty {
            EmptyState(icon: .tinkersSatchel, title: "Your bag is empty", message: "Defeat creatures and open chests to find gear.")
                .accessibilityIdentifier("gear.bagEmpty")
        } else {
            VStack(spacing: 8) {
                ForEach(Self.ordered(inventory.bag)) { item in
                    Button { selected = item } label: { ItemRow(item: item) }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("gear.bagItem")
                }
            }
        }
    }

    /// The bag in slot order, rarest first within a slot.
    static func ordered(_ bag: [GearItem]) -> [GearItem] {
        func slot(_ item: GearItem) -> Int { GearSlotId.all.firstIndex(of: item.slot) ?? GearSlotId.all.count }
        func rank(_ item: GearItem) -> Int { [ItemRarity.legendary, ItemRarity.rare].firstIndex(of: item.rarity.uppercased()) ?? 2 }
        return bag.sorted { (slot($0), rank($0), $0.name) < (slot($1), rank($1), $1.name) }
    }

    @ViewBuilder
    private func consumables(_ inventory: InventoryState, model: GearModel) -> some View {
        if !inventory.consumables.isEmpty {
            Eyebrow(text: "Lamps, map pieces and more", color: Theme.Colors.terracottaDeep).padding(.top, 4)
            VStack(spacing: 8) {
                ForEach(inventory.consumables) { stack in
                    ConsumableRow(stack: stack, busy: model.busy == stack.id) { Task { await model.use(stack) } }
                        .disabled(model.busy != nil)
                }
            }
        }
    }
}

/// One slot: its mark (faint while empty), its name, and what is worn or when it opens.
struct SlotRow: View {
    let slot: GearSlot
    var inBag = 0

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let item = slot.item {
                    MarkView(.of(item))
                } else {
                    MarkView(.icon(.forSlot(slot.slot))).opacity(slot.open ? 0.35 : 0.18)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: slot.name, color: slot.open ? Theme.Colors.terracottaDeep : Theme.Colors.muted)
                Text(slot.item?.name ?? (slot.open ? "Empty" : "Opens at level \(slot.opensAtLevel)"))
                    .font(Theme.Typography.text(15, .semibold))
                    .foregroundStyle(slot.item == nil ? Theme.Colors.muted : Theme.Colors.ink)
                if slot.open, slot.item == nil, inBag > 0 {
                    Text("\(inBag) in your bag to wear").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
                }
            }
            Spacer(minLength: 0)
            if slot.open {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Colors.muted)
            } else {
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.muted)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// An item as a row: its mark ringed by rarity, its name, rarity and slot, and what it does.
struct ItemRow: View {
    let item: GearItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MarkView(.of(item)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
                    RarityTag(rarity: item.rarity)
                }
                Text(item.text).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.equipped ? "Worn · \(GearSlotId.name(item.slot))" : GearSlotId.name(item.slot))
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "Rare", in the colour of its ring.
struct RarityTag: View {
    let rarity: String?

    var body: some View {
        if let name = ItemRarity.name(rarity) {
            Text(name)
                .font(Theme.Typography.text(11, .bold, relativeTo: .caption2))
                .foregroundStyle(Self.color(rarity))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .overlay(Capsule().stroke(Self.color(rarity).opacity(0.6), lineWidth: 1))
        }
    }

    static func color(_ rarity: String?) -> Color {
        switch rarity?.uppercased() {
        case ItemRarity.legendary: return Theme.Colors.terracottaDeep
        case ItemRarity.rare: return Theme.Colors.scribe
        default: return Theme.Colors.muted
        }
    }
}

/// A consumable: how many, what it does, and the button to use it when it is used by hand.
struct ConsumableRow: View {
    let stack: ConsumableStack
    var busy = false
    let onUse: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MarkView(.of(stack)).frame(width: 36, height: 36).opacity(stack.count >= 1 ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(stack.name) ×\(stack.count)").font(Theme.Typography.text(15, .semibold))
                    .foregroundStyle(stack.count >= 1 ? Theme.Colors.ink : Theme.Colors.muted)
                Text(stack.text).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if ConsumableId.usableFromTheBag(stack.id), stack.count >= 1 {
                    Button(action: onUse) {
                        HStack(spacing: 6) {
                            if busy { ProgressView().tint(Theme.Colors.ink) }
                            Text(Self.verb(stack))
                        }
                    }
                    .buttonStyle(.surfacePill)
                    .padding(.top, 4)
                    .accessibilityIdentifier("gear.use.\(stack.id)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gear.consumable.\(stack.id)")
    }

    /// A verb and a noun: "Use map piece", "Open sealed chest".
    static func verb(_ stack: ConsumableStack) -> String {
        switch stack.id {
        case ConsumableId.mapPiece: return "Use map piece"
        case ConsumableId.sealedChestCommon, ConsumableId.sealedChestRare: return "Open sealed chest"
        default: return "Use \(stack.name.lowercased())"
        }
    }
}

/// A row that goes somewhere: a game icon, a title, a chevron.
struct GearLinkRow: View {
    let title: String
    let icon: GameIcon

    var body: some View {
        HStack(spacing: 12) {
            IconShape(icon).foregroundStyle(Theme.Colors.ink).frame(width: 22, height: 22).frame(width: 24)
            Text(title).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

/// A line of good news in sage, for what was just done.
struct NoticeLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageText)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.sageTint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One slot: what is worn there, and the items in the bag that go in it.
struct GearSlotScreen: View {
    let slot: String
    let model: GearModel
    @State private var selected: GearItem?

    private var current: GearSlot? { model.inventory?.slots.first { $0.slot == slot } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = model.error { ErrorLine(text: error) }
                if let notice = model.notice { NoticeLine(text: notice) }
                if let current {
                    if !current.open {
                        EmptyState(icon: .forSlot(slot), title: "Opens at level \(current.opensAtLevel)",
                                   message: "Reach level \(current.opensAtLevel) to wear something here.")
                    } else if let worn = current.item {
                        SectionHeader(title: "Worn")
                        Button { selected = worn } label: { ItemRow(item: worn) }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("slot.worn")
                        Button("Take item off") { Task { await model.takeOff(worn) } }
                            .buttonStyle(.surfacePill)
                            .disabled(model.busy != nil)
                            .accessibilityIdentifier("slot.takeOff")
                    } else {
                        Text("Nothing worn here yet.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    let items = model.inventory?.bagItems(for: slot) ?? []
                    SectionHeader(title: "In your bag", subtitle: "\(items.count)")
                    if items.isEmpty {
                        EmptyState(icon: .forSlot(slot), title: "Nothing for this slot yet",
                                   message: "Defeat creatures, open chests or visit the stall to find some.")
                    }
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { selected = item } label: { ItemRow(item: item) }
                                .buttonStyle(.pressable)
                                .accessibilityIdentifier("slot.bagItem")
                            if current.open {
                                Button("Wear item") { Task { await model.wear(item) } }
                                    .buttonStyle(.surfacePill)
                                    .disabled(model.busy != nil)
                                    .accessibilityIdentifier("slot.wear")
                            }
                        }
                    }
                }
            }
            .padding(22)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .navigationTitle(current?.name ?? GearSlotId.name(slot))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { item in ItemDetailSheet(itemId: item.id, model: model) }
    }
}

/// One item: its mark, rarity and slot, what it does, and Wear, Take off and Sell.
struct ItemDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let itemId: UUID
    let model: GearModel
    @State private var confirmingSale = false

    /// The item as the bag has it now: it may have been worn or taken off since.
    private var item: GearItem? {
        guard let inventory = model.inventory else { return nil }
        return (inventory.worn + inventory.bag).first { $0.id == itemId }
    }

    private func slot(of item: GearItem) -> GearSlot? { model.inventory?.slots.first { $0.slot == item.slot } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let item {
                        details(item)
                    } else {
                        Text("It's gone from your bag.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    if let error = model.error { ErrorLine(text: error) }
                }
                .padding(22)
            }
            .background(Theme.Colors.cream)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LoreCopy.done) { dismiss() }.accessibilityIdentifier("item.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func details(_ item: GearItem) -> some View {
        HStack {
            Spacer()
            MarkView(.of(item), label: item.name).frame(width: 110, height: 110)
            Spacer()
        }
        HStack(spacing: 8) {
            RarityTag(rarity: item.rarity)
            Eyebrow(text: GearSlotId.name(item.slot), color: Theme.Colors.muted)
        }
        Text(item.name).font(Theme.Typography.voice(26, relativeTo: .title)).foregroundStyle(Theme.Colors.ink)
        Text(item.text).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
        let open = slot(of: item)?.open ?? false
        if item.equipped {
            Text("You're wearing it.").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
            Button("Take item off") { Task { await model.takeOff(item) } }
                .buttonStyle(.secondaryWide)
                .disabled(model.busy != nil)
                .accessibilityIdentifier("item.takeOff")
        } else if open {
            Button("Wear item") { Task { await model.wear(item) } }
                .buttonStyle(.primary)
                .disabled(model.busy != nil)
                .accessibilityIdentifier("item.wear")
        } else if let slot = slot(of: item) {
            Text("The \(slot.name.lowercased()) slot opens at level \(slot.opensAtLevel).")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        }
        if let price = item.sellPrice {
            Button("Sell item · \(LoreCopy.purse(price))") { confirmingSale = true }
                .buttonStyle(.secondaryWide)
                .disabled(item.equipped || model.busy != nil)
                .accessibilityIdentifier("item.sell")
                .confirmationDialog("Sell \(item.name) for \(LoreCopy.purse(price))?", isPresented: $confirmingSale, titleVisibility: .visible) {
                    Button("Sell item") {
                        Task {
                            await model.sell(item)
                            if model.error == nil { dismiss() }
                        }
                    }
                    .accessibilityIdentifier("item.sellConfirm")
                    Button("Keep item", role: .cancel) {}
                }
            if item.equipped {
                Text("Take it off before you sell it.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
        if model.busy == item.id.uuidString { ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity) }
    }
}
