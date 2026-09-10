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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                ClassEmblem(characterClass: character.characterClass, size: 84, inverted: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(character.name).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).lineLimit(1).minimumScaleFactor(0.7)
                    Text("\(ClassStyle.name(character.characterClass)) — Level \(character.classLevel)").font(Theme.Typography.text(14, .semibold))
                    if let title = character.title {
                        Text("“\(title)”").font(Theme.Typography.caption).opacity(0.85)
                    }
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
        .buttonStyle(.plain)
        .disabled(!state.canUnlock)
        .accessibilityLabel("\(state.ability.name). \(state.ability.description)")
    }
}
