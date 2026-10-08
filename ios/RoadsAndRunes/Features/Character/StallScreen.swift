import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The stall (0.7.2): four things a week, two of gear and two to use, bought with
/// coins. It opens at level 3; before that it says when.
struct StallScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var stall: Stall?
    @State private var error: String?
    @State private var buying: String?
    @State private var notice: String?
    /// The server has no stall (one from before 0.7.2).
    @State private var missing = false

    private var purse: Int { container.session.character?.activeCoins ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Your purse").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    CoinPill(coins: purse)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stall.purse")
                if missing {
                    EmptyState(icon: .shop, title: "The stall isn't here yet", message: "It arrives with the next server update.")
                }
                if let error { ErrorLine(text: error) }
                if let notice { NoticeLine(text: notice).accessibilityIdentifier("stall.notice") }
                if let stall {
                    if stall.open {
                        Text(weekLine(stall)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        ForEach(stall.offers) { offer in offerRow(offer) }
                    } else {
                        EmptyState(icon: .shop, title: "The stall opens at level \(stall.opensAtLevel)",
                                   message: "Reach level \(stall.opensAtLevel) to buy gear, lamps and map pieces here. New things every week.")
                            .accessibilityIdentifier("stall.closed")
                    }
                } else if !missing, error == nil {
                    ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                }
            }
            .padding(22)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("The stall")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    /// "Five things this week. New ones in 3 days."
    private func weekLine(_ stall: Stall) -> String {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six"]
        let count = words.indices.contains(stall.offers.count) ? words[stall.offers.count] : "\(stall.offers.count)"
        let things = "\(count) \(stall.offers.count == 1 ? "thing" : "things") this week."
        guard let resets = stall.resetsAt else { return things }
        let days = max(0, Int(ceil(resets.timeIntervalSinceNow / 86_400)))
        switch days {
        case 0, 1: return "\(things) New ones tomorrow."
        default: return "\(things) New ones in \(days) days."
        }
    }

    private func offerRow(_ offer: StallOffer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if offer.lookKind == .ink, let hex = CosmeticCatalog.inkHex(offer.itemId, color: offer.color) {
                        // An ink shows its colour.
                        Circle().fill(Color(hex: hex)).overlay(Circle().stroke(Theme.Colors.ink.opacity(0.3), lineWidth: 1))
                            .padding(4)
                    } else if offer.lookKind == .markerFrame {
                        MarkerFrameSample(frame: LookStyle.MarkerFrame(offer.itemId))
                    } else if offer.lookKind == .crestFrame {
                        FramedCrest(characterClass: container.session.character?.characterClass ?? .explorer, size: 36, frameId: offer.itemId)
                    } else {
                        MarkView(.of(offer))
                    }
                }
                .frame(width: 44, height: 44).opacity(offer.bought ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(offer.name).font(Theme.Typography.text(16, .semibold)).foregroundStyle(Theme.Colors.ink)
                        RarityTag(rarity: offer.rarity)
                    }
                    if let slot = offer.slot {
                        Text(GearSlotId.name(slot)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    } else if let kind = offer.lookKind {
                        Text(kind.name).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    Text(offer.text).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if offer.bought {
                Label("Bought this week", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
            } else {
                Button {
                    Task { await buy(offer) }
                } label: {
                    HStack(spacing: 6) {
                        if buying == offer.id { ProgressView().tint(Theme.Colors.ink) }
                        Text("Buy item · \(LoreCopy.purse(offer.price))")
                    }
                }
                .buttonStyle(.surfacePill)
                .disabled(buying != nil || purse < offer.price)
                .accessibilityIdentifier("stall.buy.\(offer.id)")
                if purse < offer.price {
                    Text("You need \(LoreCopy.purse(offer.price - purse)) more. Open chests and defeat creatures to earn them.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stall.offer.\(offer.id)")
    }

    private func load() async {
        do {
            stall = try await container.api.stall()
            error = nil
        } catch let failure as APIError where failure.isNotFound {
            missing = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func buy(_ offer: StallOffer) async {
        buying = offer.id
        defer { buying = nil }
        do {
            container.session.take(inventory: try await container.api.buyOffer(id: offer.id))
            if offer.isCosmetic {
                notice = "Bought \(offer.name). Wear it from Look on your character."
            } else {
                notice = offer.isGear ? "Bought \(offer.name). It's in your bag." : "Bought \(offer.name.lowercased())."
            }
            error = nil
            await container.session.refreshCharacter()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Coin history (0.7.2): every coin in and out of the purse, newest first, in plain words.
struct CoinHistoryScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var lines: [WalletTransaction] = []
    @State private var wallet: Wallet?
    @State private var cursor: String?
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    FactTile(value: (wallet?.balance ?? container.session.character?.activeCoins ?? 0).formatted(), label: "In your purse",
                             valueColor: Theme.Colors.terracottaDeep)
                    FactTile(value: (wallet?.lifetimeEarned ?? 0).formatted(), label: "Earned in all")
                }
                .accessibilityIdentifier("coins.purse")
                // Real rewards set against the purse (0.7.3), kept on this phone.
                SavingsGoalsSection(purse: wallet?.balance ?? container.session.character?.activeCoins ?? 0)
                if let error { ErrorLine(text: error) }
                if loaded, lines.isEmpty, error == nil {
                    EmptyState(icon: .purse, title: "No coins yet", message: "Open chests and defeat creatures to fill your purse.")
                        .accessibilityIdentifier("coins.empty")
                }
                if !lines.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            row(line)
                            if line.id != lines.last?.id { Divider().overlay(Theme.Colors.line) }
                        }
                    }
                    .card()
                }
                if cursor != nil {
                    Button(loadingMore ? "Loading…" : "Show more") { Task { await more() } }
                        .buttonStyle(.surfacePill)
                        .disabled(loadingMore)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("coins.more")
                }
                if !loaded, error == nil { ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity) }
            }
            .padding(22)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("Coin history")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ line: WalletTransaction) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.kind.label).font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                Text(line.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer(minLength: 8)
            Text(line.amount >= 0 ? "+\(line.amount.formatted())" : "−\((-line.amount).formatted())")
                .font(Theme.Typography.text(15, .bold).monospacedDigit())
                .foregroundStyle(line.amount >= 0 ? Theme.Colors.sageDeep : Theme.Colors.terracottaDeep)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.kind.label), \(line.amount >= 0 ? "plus" : "minus") \(LoreCopy.purse(abs(line.amount)))")
        .accessibilityIdentifier("coins.row")
    }

    private func load() async {
        do {
            let first = try await container.api.walletTransactions(limit: 50, cursor: nil)
            wallet = try? await container.api.wallet()
            lines = first.items
            cursor = first.nextCursor
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func more() async {
        guard let cursor else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = try await container.api.walletTransactions(limit: 50, cursor: cursor)
            let known = Set(lines.map(\.id))
            lines += next.items.filter { !known.contains($0.id) }
            self.cursor = next.nextCursor
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// What each level gives (0.7.2): fifty levels, each with something, the ones reached ticked.
struct LevelsScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var levels: [LevelStep] = []
    @State private var error: String?
    @State private var missing = false

    private var current: Int { container.session.character?.overallLevel ?? 1 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if missing {
                        EmptyState(icon: .levelUp, title: "Level rewards aren't here yet", message: "They arrive with the next server update.")
                    }
                    if let error { ErrorLine(text: error) }
                    if !levels.isEmpty {
                        Text("Every level gives something. You're level \(current).")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    ForEach(levels) { step in
                        LevelRow(step: step, current: step.level == current).id(step.level)
                    }
                    if levels.isEmpty, !missing, error == nil {
                        ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                    }
                }
                .padding(22)
                .padding(.bottom, Theme.Layout.tabBarClearance)
            }
            .onChange(of: levels.count) { _, _ in
                proxy.scrollTo(min(50, current + 1), anchor: .center)
            }
        }
        .background(Theme.Colors.cream)
        .navigationTitle("What each level gives")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            levels = try await container.api.levelRewards()
            error = nil
        } catch let failure as APIError where failure.isNotFound {
            missing = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LevelRow: View {
    let step: LevelStep
    var current = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step.level)")
                .font(Theme.Typography.text(16, .bold).monospacedDigit())
                .foregroundStyle(step.reached ? Theme.Colors.cream : Theme.Colors.muted)
                .frame(width: 40, height: 40)
                .background(step.reached ? Theme.Colors.sageDeep : Theme.Colors.track, in: Circle())
                .overlay(Circle().stroke(current ? Theme.Colors.terracotta : .clear, lineWidth: 2))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(step.rewards.enumerated()), id: \.offset) { _, reward in
                    LevelRewardLine(reward: reward, dimmed: !step.reached)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(current ? Theme.Colors.terracottaTint : Theme.Colors.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Level \(step.level)\(step.reached ? ", reached" : ""): \(step.rewards.map(\.text).joined(separator: ", "))")
        .accessibilityIdentifier("levels.row.\(step.level)")
    }
}

/// One thing a level gives, with its mark: "Lantern slot opens", "2 lamps".
struct LevelRewardLine: View {
    let reward: LevelReward
    var dimmed = false
    var textColor: Color = Theme.Colors.ink

    var body: some View {
        HStack(spacing: 8) {
            MarkView(.of(reward)).frame(width: 22, height: 22)
            Text(reward.text).font(Theme.Typography.text(14, .semibold))
                .foregroundStyle(dimmed ? Theme.Colors.muted : textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(dimmed ? 0.75 : 1)
    }
}

/// Shown once after 0.7.2 arrives: what the levels already reached gave.
struct LevelRewardsSheet: View {
    let rewards: [LevelReward]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHandle().frame(maxWidth: .infinity)
            Eyebrow(text: "Every level pays", color: Theme.Colors.sageDeep)
            Text("Rewards for the levels you've reached")
                .font(Theme.Typography.voice(26, relativeTo: .title)).foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("They're yours now: look for them in Gear and on your character.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(rewards.enumerated()), id: \.offset) { _, reward in LevelRewardLine(reward: reward) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(LoreCopy.done, action: onDone)
                .buttonStyle(.primary)
                .accessibilityIdentifier("levelRewards.done")
        }
        .padding(22)
        .background(Theme.Colors.cream.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("levelRewards")
        .presentationDetents([.medium, .large])
    }
}
