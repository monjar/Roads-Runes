import RoadsAndRunesCore
import SwiftUI

struct XPBar: View {
    let title: String
    let level: Int
    let xp: Int
    let floorXP: Int
    let nextXP: Int?

    private var fraction: Double {
        guard let nextXP, nextXP > floorXP else { return 1 }
        return min(1, max(0, Double(xp - floorXP) / Double(nextXP - floorXP)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("\(title) \(level)").font(Theme.Typography.caption.weight(.semibold))
                Spacer()
                Text(nextXP.map { "\(xp) / \($0) XP" } ?? "\(xp) XP · MAX").font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.Colors.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Colors.parchmentDeep)
                    Capsule().fill(LinearGradient(colors: [Theme.Colors.rune, Theme.Colors.ember], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 10)
        }
    }
}

struct CharacterHeader: View {
    let character: Character

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    Circle().fill(Theme.Colors.parchmentDeep)
                    Image(systemName: classIcon).font(.system(size: 30)).foregroundStyle(Theme.Colors.moss)
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name).font(Theme.Typography.title)
                    Text([character.title, character.characterClass.rawValue.capitalized].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                if character.unspentAbilityPoints > 0 {
                    Text("\(character.unspentAbilityPoints) ability point\(character.unspentAbilityPoints == 1 ? "" : "s")")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .padding(.horizontal, Theme.Spacing.sm).padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Colors.rune.opacity(0.2), in: Capsule())
                }
            }
            XPBar(title: "Level", level: character.overallLevel, xp: character.overallXP, floorXP: character.overallLevelFloorXP, nextXP: character.nextOverallLevelXP)
            XPBar(title: "\(character.characterClass.rawValue.capitalized) level", level: character.classLevel, xp: character.classXP, floorXP: character.classLevelFloorXP, nextXP: character.nextClassLevelXP)
        }
        .card()
    }

    private var classIcon: String {
        switch character.characterClass {
        case .explorer: return "map"
        case .wizard: return "wand.and.stars"
        case .warrior: return "mountain.2"
        case .scribe: return "book.closed"
        default: return "person"
        }
    }
}

struct AbilityCard: View {
    let state: AbilityState
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(state.ability.name).font(Theme.Typography.heading)
                Spacer()
                if state.unlocked {
                    Text("Rank \(state.rank)/\(state.ability.maxRank)").font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.Colors.rune)
                } else {
                    Label("Lv \(state.ability.requiredClassLevel)", systemImage: "lock").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Text(state.ability.description).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            if state.canUnlock {
                Button(state.unlocked ? "Upgrade" : "Unlock", action: action).buttonStyle(.borderedProminent).tint(Theme.Colors.moss).controlSize(.small)
            }
        }
        .card()
        .opacity(state.unlocked || state.canUnlock ? 1 : 0.6)
    }
}
