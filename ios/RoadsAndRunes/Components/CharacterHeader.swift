import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

struct XPBar: View {
    let title: String
    let level: Int
    let xp: Int
    let floorXP: Int
    let nextXP: Int?
    var fill: Color = Theme.Colors.sage
    var track: Color = Theme.Colors.track
    var foreground: Color = Theme.Colors.ink
    var secondary: Color = Theme.Colors.muted

    private var fraction: Double {
        guard let nextXP, nextXP > floorXP else { return 1 }
        return min(1, max(0, Double(xp - floorXP) / Double(nextXP - floorXP)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(title) \(level)").font(Theme.Typography.captionStrong).foregroundStyle(foreground)
                Spacer()
                Text(nextXP.map { "\(xp.formatted()) / \($0.formatted()) XP" } ?? "\(xp.formatted()) XP · max")
                    .font(Theme.Typography.captionStrong.monospacedDigit()).foregroundStyle(secondary)
            }
            ProgressTrack(fraction: fraction, fill: fill, track: track, height: 8)
        }
    }
}

/// Character sheet header (design 11b): class-coloured block with rings, the
/// heraldic mark on cream, name, class and level, title, class XP.
struct CharacterHeader: View {
    let character: Character

    private var color: Color { ClassStyle.color(character.characterClass) }

    /// "Explorer, of the Wayfinders · level 6".
    private var tradeLine: String {
        let name = ClassStyle.name(character.characterClass)
        let guild = ClassStyle.guild(character.characterClass).map { ", of \($0)" } ?? ""
        return "\(name)\(guild) · level \(character.classLevel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ClassEmblem(characterClass: character.characterClass, size: 84, inverted: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(character.name).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).lineLimit(1).minimumScaleFactor(0.7)
                    Text(tradeLine).font(Theme.Typography.text(14, .semibold))
                    if let title = character.title {
                        TitleRibbon(title: title)
                            .accessibilityIdentifier("character.title")
                    }
                    HStack(spacing: 8) {
                        if let coins = character.activeCoins {
                            CoinPill(coins: coins, foreground: Theme.Colors.cream)
                                .accessibilityIdentifier("character.coins")
                        }
                        if let days = character.streakDays, days > 0 {
                            HStack(spacing: 4) {
                                MarkView(.icon(.campfire, spot: .paper)).frame(width: 13, height: 13)
                                Text("\(days) day\(days == 1 ? "" : "s")").font(Theme.Typography.text(12, .semibold))
                            }
                            .foregroundStyle(Theme.Colors.cream)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(Capsule().stroke(Theme.Colors.cream.opacity(0.35), lineWidth: 1))
                            .accessibilityLabel(LoreCopy.daysKept(days))
                            .accessibilityIdentifier("character.streak")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            XPBar(
                title: ClassStyle.name(character.characterClass),
                level: character.classLevel,
                xp: character.classXP,
                floorXP: character.classLevelFloorXP,
                nextXP: character.nextClassLevelXP,
                fill: Theme.Colors.cream,
                track: Theme.Colors.ink.opacity(0.25),
                foreground: Theme.Colors.cream,
                secondary: Theme.Colors.cream
            )
            XPBar(
                title: "Overall",
                level: character.overallLevel,
                xp: character.overallXP,
                floorXP: character.overallLevelFloorXP,
                nextXP: character.nextOverallLevelXP,
                fill: Theme.Colors.cream.opacity(0.7),
                track: Theme.Colors.ink.opacity(0.25),
                foreground: Theme.Colors.cream.opacity(0.9),
                secondary: Theme.Colors.cream.opacity(0.9)
            )
        }
        .foregroundStyle(Theme.Colors.cream)
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                color
                RingPattern(color: Theme.Colors.cream, opacity: 0.12, step: 12).frame(width: 320, height: 320).offset(x: 40, y: -60)
            }
        )
    }
}

/// Compact character chip for the World (design 9a): emblem, "Name · Explorer 8", XP bar.
struct CharacterChip: View {
    let character: Character

    var body: some View {
        HStack(spacing: 10) {
            ClassEmblem(characterClass: character.characterClass, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(character.name) · \(ClassStyle.name(character.characterClass)) \(character.classLevel)")
                    .font(Theme.Typography.text(13, .bold))
                    .foregroundStyle(Theme.Colors.cream)
                    .lineLimit(1)
                ProgressTrack(fraction: character.classLevelProgress, fill: ClassStyle.lightColor(character.characterClass), track: Theme.Colors.inkSoft, height: 4)
                    .frame(width: 110)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .background(Theme.Colors.ink, in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.2), radius: 5, y: 3)
    }
}

/// What the board calls you, on a ribbon with cut ends.
struct TitleRibbon: View {
    let title: String
    var ink: Color = Theme.Colors.ink
    var paper: Color = Theme.Colors.cream

    var body: some View {
        Text(title)
            .font(Theme.Typography.text(12.5, .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(RibbonShape().fill(paper))
            .accessibilityLabel("Title: \(title)")
    }
}

/// A banner with a swallow-tail notch at each end.
struct RibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notch = min(8, rect.height * 0.45)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + notch, y: rect.midY))
        p.closeSubpath()
        return p
    }
}

/// A knack as a row you can read: its name, its ranks, what it does, and plainly
/// whether the server acts on it yet. Most were promised before they did
/// anything (docs/ROADMAP.md, 0.6.2); the sheet says "not yet" rather than
/// advertise them.
struct KnackRow: View {
    let state: AbilityState
    var color: Color = Theme.Colors.sage
    let learn: () -> Void

    /// The server says whether it acts on a knack; one from before 0.6.0 does not, and
    /// read only these two effects.
    private var working: Bool {
        state.ability.working ?? state.ability.effects.contains { ["QUEST_POI_VISIBILITY", "UNLOCK_TEMPLATE"].contains($0.type) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(state.unlocked ? color : Color.clear)
                .overlay(Circle().strokeBorder(state.unlocked ? .clear : Theme.Colors.hatch, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                .frame(width: 14, height: 14)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.ability.name).font(Theme.Typography.bodyStrong).foregroundStyle(Theme.Colors.ink)
                    if state.ability.maxRank > 1 {
                        Text("\(state.rank) of \(state.ability.maxRank)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    if !working {
                        Text("not yet").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.muted)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Theme.Colors.hatch, lineWidth: 1))
                    }
                }
                Text(state.ability.description).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.unlocked, !state.canUnlock {
                    Text("From trade level \(state.ability.requiredClassLevel)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
            }
            Spacer(minLength: 8)
            if state.canUnlock {
                Button("Learn", action: learn).buttonStyle(.surfacePill)
                    .accessibilityLabel("Learn \(state.ability.name)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Ability as a pill: filled in class colour when unlocked, dashed with the
/// unlock level otherwise. Tapping an unlockable one spends the point.
struct AbilityCard: View {
    let state: AbilityState
    var color: Color = Theme.Colors.sage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if state.unlocked {
                    Text(state.ability.name)
                    if state.ability.maxRank > 1 { Text("\(state.rank)/\(state.ability.maxRank)").opacity(0.8) }
                } else {
                    Text("\(state.ability.name) · Lv \(state.ability.requiredClassLevel)")
                }
            }
            .font(Theme.Typography.captionStrong)
            .foregroundStyle(state.unlocked ? Theme.Colors.cream : (state.canUnlock ? Theme.Colors.terracottaDeep : Theme.Colors.muted))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(state.unlocked ? color : .clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    state.unlocked ? .clear : (state.canUnlock ? Theme.Colors.terracotta : Theme.Colors.hatch),
                    style: StrokeStyle(lineWidth: 1.5, dash: state.unlocked || state.canUnlock ? [] : [4, 3])
                )
            )
        }
        .buttonStyle(.pressable)
        .disabled(!state.canUnlock)
        .accessibilityLabel("\(state.ability.name). \(state.ability.description)")
    }
}


/// "◎ 120": the purse, wherever the character is shown.
struct CoinPill: View {
    let coins: Int
    var foreground: Color = Theme.Colors.ink

    var body: some View {
        HStack(spacing: 5) {
            MarkView(.coin).frame(width: 14, height: 14)
            Text(coins.formatted()).font(Theme.Typography.text(12, .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .overlay(Capsule().stroke(foreground.opacity(0.35), lineWidth: 1))
        .accessibilityLabel(LoreCopy.purse(coins))
    }
}
