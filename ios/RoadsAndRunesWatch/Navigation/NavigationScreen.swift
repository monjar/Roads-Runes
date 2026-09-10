import RoadsAndRunesCore
import SwiftUI

/// Primary Watch screen (design 7a, screen 2): terracotta arrow, huge distance,
/// direction word, street; speed small at the bottom.
struct NavigationScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 2) {
                if let instruction = store.currentInstruction {
                    TurnArrow(sign: instruction.sign)
                    distanceText(store.currentDistanceToInstruction ?? instruction.distanceMeters)
                    Text(TurnArrow.word(for: instruction.sign))
                        .font(.system(size: 15, weight: .bold))
                        .tracking(1.5)
                        .padding(.top, 2)
                    Text(instruction.streetName.isEmpty ? instruction.text : instruction.streetName)
                        .font(.system(size: 13))
                        .foregroundStyle(WatchTheme.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                    Spacer(minLength: 0)
                    footer(context.date)
                } else {
                    Image(systemName: "location.north.line.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(WatchTheme.accent)
                    Text(store.hasRoute ? "Waiting for the first turn" : "Free ride")
                        .font(.system(size: 14, weight: .semibold))
                    Text(store.hasRoute ? "Directions start when you move" : "Every new road counts")
                        .font(.system(size: 12))
                        .foregroundStyle(WatchTheme.secondary)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                    footer(context.date)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
        }
    }

    private func distanceText(_ meters: Double) -> some View {
        let parts = split(store.formatter.distance(meters: meters))
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(parts.value)
                .font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
            Text(parts.unit)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private func footer(_ date: Date) -> some View {
        if store.isStale(at: date) {
            Label(store.phoneReachable ? "No updates" : "iPhone offline", systemImage: "iphone.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WatchTheme.accent)
        } else if store.isPaused {
            Text("PAUSED")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(WatchTheme.secondary)
        } else if let speed = store.update?.speedMps {
            (Text(store.formatter.speedValue(metersPerSecond: speed).formatted(.number.precision(.fractionLength(1)))).bold().foregroundStyle(.white)
                + Text(" \(store.formatter.speedUnitLabel)").foregroundStyle(WatchTheme.secondary))
                .font(.system(size: 14))
        }
    }

    private func split(_ distance: String) -> (value: String, unit: String) {
        guard let space = distance.lastIndex(of: " ") else { return (distance, "") }
        return (String(distance[..<space]), String(distance[distance.index(after: space)...]))
    }
}
