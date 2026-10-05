import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Quest page (design 16a): diamond and QUEST eyebrow in sage, the quest name,
/// the fight beside it (0.7.2), the current objective, the distance to it, progress.
struct QuestScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WatchTheme.sageLight)
                            .frame(width: 10, height: 10)
                            .rotationEffect(.degrees(45))
                        Text("QUEST")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(WatchTheme.sageLight)
                    }
                    Text(store.questTitle ?? LoreCopy.free(store.activity))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WatchTheme.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 2)
                }
                // The fight: a mark and a ring, nothing more to read on the move.
                if let fight = store.fight {
                    Spacer(minLength: 0)
                    FightRing(fight: fight)
                        .frame(width: 42, height: 42)
                }
            }
            if let encounter = store.encounterLine {
                Text(encounter)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WatchTheme.accent)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            if let objective = store.objectiveTitle {
                Text("OBJECTIVE")
                    .font(.system(size: 11))
                    .foregroundStyle(WatchTheme.tertiary)
                    .padding(.top, 10)
                Text(objective)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let distance = store.objectiveDistanceMeters {
                    let parts = split(store.formatter.distance(meters: distance))
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(parts.value)
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        Text(parts.unit)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(WatchTheme.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
                Text(progressText)
                    .font(.system(size: 12))
                    .foregroundStyle(WatchTheme.tertiary)
            } else {
                Spacer(minLength: 0)
                Text(store.questTitle == nil ? "Every new road counts" : "All objectives complete")
                    .font(.system(size: 14))
                    .foregroundStyle(WatchTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var progressText: String {
        let total = store.summary?.objectives.count ?? 0
        guard total > 0 else { return "" }
        let done = store.summary?.objectives.filter { $0.title != store.objectiveTitle }.count ?? 0
        return "\(min(done + 1, total)) of \(total) objectives"
    }

    private func split(_ distance: String) -> (value: String, unit: String) {
        guard let space = distance.lastIndex(of: " ") else { return (distance, "") }
        return (String(distance[..<space]), String(distance[distance.index(after: space)...]))
    }
}

/// The creature being fought, inside its health drawn as ten ticks (`HoldRing`):
/// redrawn in whole tenths, with no numbers and no animation. Defeated, the ring
/// is empty and the mark fades.
struct FightRing: View {
    let fight: WatchFight

    var body: some View {
        ZStack {
            HoldRing(fraction: Self.fraction(tenths: fight.tenthsLeft), palette: .watch, lineWidth: 3)
            MarkView(WristMarks.fight(fight), palette: .watch)
                .padding(7)
                .opacity(fight.defeated ? 0.45 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fight.defeated ? "\(fight.name), defeated" : "\(fight.name), health \(fight.tenthsLeft) of 10")
    }

    /// Half a tenth under the count, so the ring's rounding up lands on it exactly.
    static func fraction(tenths: Int) -> Double {
        tenths <= 0 ? 0 : (Double(min(10, tenths)) - 0.5) / 10
    }
}
