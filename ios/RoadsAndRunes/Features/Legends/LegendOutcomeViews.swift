import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Journey's end's legend stage (0.8.0): what the journey did to it, the phase
/// it is in now as a bar, "Phase broken!" when one broke, and what that paid —
/// coins, XP, an item, and on its defeat its Hard rune and a title.
struct LegendOutcomeSection: View {
    let outcome: LegendOutcome

    private var celebrated: Bool { outcome.phaseBroken || outcome.defeated }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                MarkView(.legend(icon: outcome.icon)).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    if outcome.defeated {
                        Eyebrow(text: "Legend defeated!", color: Theme.Colors.terracottaDeep)
                    } else if outcome.phaseBroken {
                        Eyebrow(text: LegendCopy.phaseBroken, color: Theme.Colors.terracottaDeep).accessibilityIdentifier("summary.phaseBroken")
                    } else {
                        Eyebrow(text: "A legend", color: Theme.Colors.muted)
                    }
                    Text(LegendCopy.outcome(outcome))
                        .font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !outcome.defeated {
                HStack(spacing: 10) {
                    Text("Phase \(outcome.phaseAfter)").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                    PhaseBar(fraction: outcome.fraction, current: true).frame(height: 12)
                    Text("\(outcome.phaseLeft) / \(outcome.phaseMax)")
                        .font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Phase \(outcome.phaseAfter)")
                .accessibilityValue("Health \(outcome.phaseLeft) of \(outcome.phaseMax)")
                .accessibilityIdentifier("summary.legendBar")
            }
            if let kinds = LegendCopy.kinds(outcome.kinds) {
                Text("Damage: \(kinds)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
            }
            if let rewards = outcome.rewards { RewardLines(rewards: rewards) }
        }
        .padding(14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .stroke(Theme.Colors.gold.opacity(celebrated ? 0.85 : 0), lineWidth: 1.5))
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.legend")
    }
}

/// What a phase break or a defeat paid: coins and XP, and a title on its defeat.
/// Its items and its Hard rune are among the journey's finds and runes.
private struct RewardLines: View {
    let rewards: LegendRewards

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let paid = [rewards.coins.flatMap { $0 > 0 ? LoreCopy.earned($0) : nil }, rewards.xp.flatMap { $0 > 0 ? "+\($0) XP" : nil }]
                .compactMap { $0 }
            if !paid.isEmpty {
                Text(paid.joined(separator: " · ")).font(Theme.Typography.text(14, .bold).monospacedDigit())
                    .foregroundStyle(Theme.Colors.terracottaDeep)
            }
            if let title = rewards.title, !title.isEmpty {
                HStack(spacing: 8) {
                    MarkView(.icon(.laurels, spot: .gold)).frame(width: 20, height: 20)
                    Text("New title: \(title)").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.legendRewards")
    }
}

/// "A legend has woken: the Water Wyrm", at the end of the journey that woke it.
struct LegendWokeLine: View {
    let woke: LegendWoke

    var body: some View {
        HStack(spacing: 12) {
            MarkView(.legend(icon: woke.icon, speciesId: woke.speciesId)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(woke.line ?? LegendCopy.woke(woke.name)).font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Find it on the World map.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary.legendWoke")
    }
}

/// Journey's end's lair line: tiles visited of those it needs, or its great chest opened.
struct LairOutcomeSection: View {
    let outcome: LairOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                MarkView(outcome.done ? .greatChest : .lair).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LairCopy.outcome(outcome)).font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !outcome.done {
                        ProgressTrack(fraction: Double(outcome.visited) / Double(max(1, outcome.need)), fill: Theme.Colors.sage)
                    }
                }
            }
            // Its items and its rune are among the journey's finds and runes; the coins are said here.
            if outcome.done, let coins = outcome.rewards?.coins, coins > 0 {
                Text("Great chest: \(LoreCopy.earned(coins))").font(Theme.Typography.text(14, .bold).monospacedDigit())
                    .foregroundStyle(Theme.Colors.terracottaDeep)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.lair")
    }
}

/// Journey's end's buried treasure: opened on the way, and what it held.
struct TreasureFoundSection: View {
    let finds: [TreasureFound]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(finds.enumerated()), id: \.offset) { _, found in
                HStack(alignment: .top, spacing: 12) {
                    MarkView(.token(.openChest, ring: .gold)).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TreasureCopy.outcome(found)).font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let item = found.item {
                            HStack(spacing: 8) {
                                MarkView(.of(item)).frame(width: 24, height: 24)
                                Text(item.name).font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                                RarityTag(rarity: item.rarity)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.treasure")
    }
}
