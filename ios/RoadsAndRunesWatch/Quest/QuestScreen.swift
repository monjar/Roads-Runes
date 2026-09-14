import RoadsAndRunesCore
import SwiftUI

/// Quest page (design 16a): diamond and QUEST eyebrow in sage, the quest name,
/// the current objective, the distance to it, progress.
struct QuestScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
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
            Text(store.questTitle ?? "Free ride")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WatchTheme.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)
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
