import RoadsAndRunesCore
import SwiftUI

/// Stats page (spec §46): distance, duration, elevation, heart rate; speed small.
struct StatsScreen: View {
    @Environment(RideStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 5 : 1)) { context in
            VStack(spacing: 6) {
                StatRow(value: store.formatter.distance(meters: store.update?.distanceMeters ?? 0), label: "DISTANCE")
                StatRow(value: store.formatter.duration(seconds: store.elapsedSeconds(at: context.date)), label: "DURATION")
                StatRow(value: store.formatter.elevation(meters: store.update?.elevationGainMeters ?? 0), label: "ELEVATION")
                StatRow(value: store.heartRate.map { "\($0) bpm" } ?? "--", label: "HEART RATE", accent: true)
                if let speed = store.update?.speedMps, !isLuminanceReduced {
                    Text(store.formatter.speed(metersPerSecond: speed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct StatRow: View {
    let value: String
    let label: String
    var accent = false

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(accent ? WatchTheme.accent : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
        }
    }
}
