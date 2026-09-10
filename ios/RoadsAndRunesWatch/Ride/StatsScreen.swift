import RoadsAndRunesCore
import SwiftUI

/// Ride page (design 16a, "speed demoted"): distance first, then time, climb,
/// new territory in sage, heart rate; speed last and quiet.
struct StatsScreen: View {
    @Environment(RideStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 5 : 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text("RIDE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(WatchTheme.tertiary)
                let parts = split(store.formatter.distance(meters: store.update?.distanceMeters ?? 0))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(parts.value)
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    Text(parts.unit)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(WatchTheme.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 10) {
                    StatRow(value: store.formatter.duration(seconds: store.elapsedSeconds(at: context.date)), label: "TIME")
                    StatRow(value: "↑ \(store.formatter.elevation(meters: store.update?.elevationGainMeters ?? 0))", label: "CLIMBED")
                    StatRow(value: store.heartRate.map { "\($0)" } ?? "--", label: "BPM", color: WatchTheme.heart)
                    if let speed = store.update?.speedMps, !isLuminanceReduced {
                        StatRow(value: store.formatter.speedValue(metersPerSecond: speed).formatted(.number.precision(.fractionLength(1))), label: store.formatter.speedUnitLabel.uppercased(), color: WatchTheme.tertiary)
                    }
                }
                .padding(.top, 12)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.top, 4)
        }
    }

    private func split(_ distance: String) -> (value: String, unit: String) {
        guard let space = distance.lastIndex(of: " ") else { return (distance, "") }
        return (String(distance[..<space]), String(distance[distance.index(after: space)...]))
    }
}

struct StatRow: View {
    let value: String
    let label: String
    var color: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WatchTheme.tertiary)
        }
    }
}
