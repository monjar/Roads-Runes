import RoadsAndRunesCore
import SwiftUI

/// Quest page (spec §45): quest title, current objective, distance to it.
struct QuestScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            Text((store.questTitle ?? "Free ride").uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 8)
            if let objective = store.objectiveTitle {
                Text("Objective")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(objective)
                    .font(.system(size: 18, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 10)
                if let distance = store.objectiveDistanceMeters {
                    Text(store.formatter.distance(meters: distance))
                        .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(WatchTheme.accent)
                }
            } else {
                Text("No objective")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
