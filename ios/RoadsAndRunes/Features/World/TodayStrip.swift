import RoadsAndRunesCore
import SwiftUI

/// The World's one line about today: whether the streak is safe, and the nearest
/// thing worth going out for. A reason to move, where the rider already looks.
struct TodayStrip: View {
    let character: Character?
    let nearest: WorldObject?
    var nearestMeters: Double?
    let activity: Activity
    let units: Units
    let onNearest: () -> Void

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        HStack(spacing: 10) {
            streak
            if let nearest {
                Divider().frame(height: 26)
                Button(action: onNearest) {
                    HStack(spacing: 8) {
                        EncounterGlyph(kind: nearest.kind, bounty: nearest.isBounty, size: 28)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(nearest.name).font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                            Text(nearestLine(nearest)).font(Theme.Typography.text(11.5, relativeTo: .caption2)).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.Colors.muted)
                    }
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("today.nearest")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.Colors.cream.opacity(0.97), in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.16), radius: 6, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today")
    }

    private var streak: some View {
        let days = character?.streakDays ?? 0
        let done = character?.streakActiveToday == true
        let color = done ? Theme.Colors.sageDeep : Theme.Colors.terracottaDeep
        return HStack(spacing: 7) {
            Image(systemName: done ? "flame.fill" : "flame").font(.system(size: 15, weight: .bold)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(streakTitle(days: days, done: done)).font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                Text(streakLine(days: days, done: done)).font(Theme.Typography.text(11.5, relativeTo: .caption2)).foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func streakTitle(days: Int, done: Bool) -> String {
        if done { return "Day \(max(days, 1)) done" }
        return days == 0 ? "Start a streak" : "\(days)-day streak"
    }

    private func streakLine(days: Int, done: Bool) -> String {
        if done {
            let next = [7, 30].first { $0 > days }
            return next.map { "\($0 - days) more to a purse" } ?? "back tomorrow"
        }
        return days == 0 ? "1 km today counts" : "1 km today keeps it"
    }

    private func nearestLine(_ object: WorldObject) -> String {
        var parts: [String] = []
        if let nearestMeters { parts.append(formatter.distance(meters: nearestMeters)) }
        parts.append("\(object.rewardAC) AC")
        if let nearestMeters, nearestMeters < 1500 { parts.append("a short \(activity.noun)") }
        return parts.joined(separator: " · ")
    }
}
