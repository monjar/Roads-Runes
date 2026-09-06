import RoadsAndRunesCore
import SwiftUI

/// Primary Watch screen (spec §44): arrow, distance, direction word, street.
struct NavigationScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 4) {
                if let instruction = store.currentInstruction {
                    TurnArrow(sign: instruction.sign)
                    Text(store.formatter.distance(meters: store.currentDistanceToInstruction ?? instruction.distanceMeters))
                        .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(TurnArrow.word(for: instruction.sign))
                        .font(.system(size: 12, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(WatchTheme.accent)
                    Text(instruction.streetName.isEmpty ? instruction.text : instruction.streetName)
                        .font(.system(size: 15, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                    if let next = store.nextInstructionText {
                        Text("then \(next)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "location.north.line")
                        .font(.system(size: 30))
                        .foregroundStyle(WatchTheme.accent)
                    Text("Waiting for route")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if store.isStale(at: context.date) {
                    Label(store.phoneReachable ? "No updates" : "iPhone offline", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.danger)
                }
                if store.isPaused {
                    Text("PAUSED")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
