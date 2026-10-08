import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI
import WidgetKit

/// The home screen and the lock screen between journeys: the streak, the
/// bounty and how far, the week's quest and the Codex. Read from the snapshot
/// the app leaves in the app group; the widget never goes to the network.
struct TodayWidget: Widget {
    static let kind = "RoadsAndRunesToday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Streak and bounty")
        .description("Your streak, today's bounty and the week's quest.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil before the app has written one: signed out, or never opened.
    let snapshot: WidgetSnapshot?

    var streak: Int { snapshot?.streak(at: date) ?? 0 }
    var keptToday: Bool {
        guard let snapshot else { return false }
        return snapshot.streakActiveToday && Calendar.current.isDate(snapshot.updatedAt, inSameDayAs: date)
    }
    var bounty: WidgetSnapshot.Bounty? { snapshot?.liveBounty(at: date) }
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let stored = WidgetSnapshot.read()
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview && stored == nil ? .placeholder : stored))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.read()
        completion(Timeline(entries: Self.entries(for: snapshot, from: now), policy: .after(Self.nextMidnight(after: now))))
    }

    /// Now, when the bounty runs out, and the next two midnights (the streak
    /// changes with the day). The app reloads the timeline whenever it writes.
    static func entries(for snapshot: WidgetSnapshot?, from now: Date, calendar: Calendar = .current) -> [SnapshotEntry] {
        var dates = [now]
        let midnight = nextMidnight(after: now, calendar: calendar)
        dates.append(midnight)
        if let after = calendar.date(byAdding: .day, value: 1, to: midnight) { dates.append(after) }
        if let expires = snapshot?.bounty?.expiresAt, expires > now { dates.append(expires) }
        return Set(dates).sorted().map { SnapshotEntry(date: $0, snapshot: snapshot) }
    }

    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(86_400)
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .systemMedium: MediumTodayView(entry: entry)
        case .accessoryCircular: CircularStreakView(entry: entry)
        case .accessoryRectangular: RectangularBountyView(entry: entry)
        case .accessoryInline: InlineTodayView(entry: entry)
        default: SmallTodayView(entry: entry)
        }
    }
}

// MARK: - Words

enum TodayLines {
    static func streakTitle(_ entry: SnapshotEntry) -> String {
        entry.streak == 0 ? "Start a streak" : LoreCopy.streak(entry.streak)
    }

    static func streakLine(_ entry: SnapshotEntry) -> String {
        if entry.keptToday { return "Done for today" }
        return entry.streak == 0 ? "Go 1 km today" : "Go 1 km today to keep it"
    }

    static func bountyDistance(_ bounty: WidgetSnapshot.Bounty, _ snapshot: WidgetSnapshot?) -> String? {
        guard let meters = bounty.distanceMeters, let snapshot else { return nil }
        return "\(snapshot.distance(meters)) away"
    }

    /// "Codex 7 / 24 · Pledged: Fen Troll", either part alone, or nothing.
    static func footer(_ snapshot: WidgetSnapshot) -> String? {
        var parts: [String] = []
        if let met = snapshot.codexMet, let total = snapshot.codexTotal, total > 0 { parts.append("Codex \(met) / \(total)") }
        if let pledge = snapshot.pledge { parts.append("Pledged: \(pledge.targetName)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let noBounty = "No bounty out right now."
    static let signedOut = "Open Roads & Runes to see your streak."
}

// MARK: - Home screen

private struct StreakBlock: View {
    let entry: SnapshotEntry
    var numberSize: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                MarkView(.icon(.campfire, spot: entry.keptToday ? .sage : .terracotta))
                    .frame(width: numberSize * 0.55, height: numberSize * 0.55)
                Text("\(entry.streak)")
                    .font(WidgetStyle.voice(numberSize, relativeTo: .largeTitle))
                    .foregroundStyle(WidgetStyle.ink)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            Text("day streak")
                .font(WidgetStyle.text(12, relativeTo: .caption))
                .foregroundStyle(WidgetStyle.muted)
            Text(TodayLines.streakLine(entry))
                .font(WidgetStyle.text(11.5, relativeTo: .caption2))
                .foregroundStyle(entry.keptToday ? WidgetStyle.sage : WidgetStyle.terracotta)
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TodayLines.streakTitle(entry)). \(TodayLines.streakLine(entry))")
    }
}

private struct BountyRow: View {
    let bounty: WidgetSnapshot.Bounty?
    let snapshot: WidgetSnapshot?
    var markSize: CGFloat = 34

    var body: some View {
        if let bounty {
            HStack(spacing: 8) {
                MarkView(.creature(icon: bounty.icon, bounty: true))
                    .frame(width: markSize, height: markSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bounty")
                        .font(WidgetStyle.text(11, relativeTo: .caption2))
                        .foregroundStyle(WidgetStyle.muted)
                    Text(bounty.name)
                        .font(WidgetStyle.voice(14, relativeTo: .headline))
                        .foregroundStyle(WidgetStyle.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if let distance = TodayLines.bountyDistance(bounty, snapshot) {
                        Text(distance)
                            .font(WidgetStyle.text(11.5, relativeTo: .caption2))
                            .foregroundStyle(WidgetStyle.muted)
                            .monospacedDigit()
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(TodayLines.noBounty)
                .font(WidgetStyle.text(12, relativeTo: .caption))
                .foregroundStyle(WidgetStyle.muted)
        }
    }
}

struct SmallTodayView: View {
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if entry.snapshot == nil {
                SignedOutView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    StreakBlock(entry: entry, numberSize: 34)
                    Spacer(minLength: 0)
                    BountyRow(bounty: entry.bounty, snapshot: entry.snapshot, markSize: 30)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .widgetURL(entry.bounty == nil ? DeepLink.world.url : DeepLink.bounty.url)
        .containerBackground(WidgetStyle.cream, for: .widget)
    }
}

struct MediumTodayView: View {
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                HStack(alignment: .top, spacing: 14) {
                    StreakBlock(entry: entry, numberSize: 40)
                        .frame(width: 104, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Link(destination: DeepLink.bounty.url) {
                            BountyRow(bounty: entry.bounty, snapshot: snapshot, markSize: 34)
                        }
                        if let week = snapshot.weekNotice {
                            Link(destination: DeepLink.quests.url) { WeekRow(week: week) }
                        }
                        if let footer = TodayLines.footer(snapshot) {
                            Text(footer)
                                .font(WidgetStyle.text(11.5, relativeTo: .caption2))
                                .foregroundStyle(WidgetStyle.muted)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                SignedOutView()
            }
        }
        .widgetURL(DeepLink.world.url)
        .containerBackground(WidgetStyle.cream, for: .widget)
    }
}

private struct WeekRow: View {
    let week: WidgetSnapshot.WeekNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(week.title)
                    .font(WidgetStyle.text(12, bold: true, relativeTo: .caption))
                    .foregroundStyle(WidgetStyle.ink)
                    .lineLimit(1)
                if week.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WidgetStyle.sage)
                        .accessibilityLabel("Done")
                }
            }
            ProgressView(value: week.progress)
                .tint(week.done ? WidgetStyle.sage : WidgetStyle.terracotta)
                .accessibilityLabel("This week's quest")
        }
    }
}

private struct SignedOutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkView(.icon(.campfire, spot: .terracotta)).frame(width: 26, height: 26)
            Text(TodayLines.signedOut)
                .font(WidgetStyle.text(13, relativeTo: .body))
                .foregroundStyle(WidgetStyle.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Lock screen

struct CircularStreakView: View {
    let entry: SnapshotEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Circle()
                .stroke(lineWidth: 3)
                .opacity(entry.keptToday ? 1 : 0.3)
                .padding(2)
            VStack(spacing: -2) {
                Text("\(entry.streak)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text("streak")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .widgetAccentable()
        .widgetURL(DeepLink.world.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TodayLines.streakTitle(entry)). \(TodayLines.streakLine(entry))")
        .containerBackground(.clear, for: .widget)
    }
}

struct RectangularBountyView: View {
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let bounty = entry.bounty {
                HStack(spacing: 6) {
                    MarkView(.creature(icon: bounty.icon, bounty: true), palette: .watch)
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Bounty").font(.system(size: 11, weight: .semibold)).widgetAccentable()
                        Text(bounty.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                        if let distance = TodayLines.bountyDistance(bounty, entry.snapshot) {
                            Text(distance).font(.system(size: 12)).monospacedDigit()
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(TodayLines.streakTitle(entry)).font(.system(size: 14, weight: .bold)).widgetAccentable()
                    Text(entry.snapshot == nil ? TodayLines.signedOut : TodayLines.noBounty)
                        .font(.system(size: 12))
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(entry.bounty == nil ? DeepLink.world.url : DeepLink.bounty.url)
        .containerBackground(.clear, for: .widget)
    }
}

struct InlineTodayView: View {
    let entry: SnapshotEntry

    var body: some View {
        Text(InlineTodayView.line(streak: entry.streak, bounty: entry.bounty?.name))
            .widgetURL(DeepLink.world.url)
            .containerBackground(.clear, for: .widget)
    }

    /// "Streak 4 · Bounty: Fen Troll".
    static func line(streak: Int, bounty: String?) -> String {
        guard let bounty else { return "Streak \(streak)" }
        return "Streak \(streak) · Bounty: \(bounty)"
    }
}

#Preview("Small", as: .systemSmall) {
    TodayWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .placeholder)
    SnapshotEntry(date: .now, snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
    TodayWidget()
} timeline: {
    SnapshotEntry(date: .now, snapshot: .placeholder)
}
