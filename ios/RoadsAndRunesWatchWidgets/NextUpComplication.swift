import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI
import WidgetKit

/// The Watch complication (0.7.3): the quarry's mark while a journey is under
/// way (a legend's in gold, 0.8.0), else today's bounty's, else the streak. It reads only what the Watch app
/// keeps in the app group (`WatchIdleStore`) and never asks the network or the phone.
@main
struct RoadsAndRunesWatchWidgets: WidgetBundle {
    var body: some Widget {
        NextUpComplication()
    }
}

struct NextUpEntry: TimelineEntry {
    let date: Date
    let face: WatchComplication
}

struct NextUpProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextUpEntry {
        NextUpEntry(date: Date(), face: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextUpEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    /// Now, then again when the bounty runs out and at midnight, when a streak not
    /// kept can lapse. The Watch app reloads the timeline whenever there is news.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextUpEntry>) -> Void) {
        let now = Date()
        let idle = WatchIdleStore.readIdle()
        let later = WatchComplication.refreshDates(idle: idle, after: now)
        let entries = ([now] + later).map { entry(at: $0, idle: idle) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date, idle: WatchIdleInfo? = WatchIdleStore.readIdle()) -> NextUpEntry {
        NextUpEntry(date: date, face: WatchComplication(idle: idle, quarry: WatchIdleStore.readQuarry(), at: date))
    }
}

struct NextUpComplication: Widget {
    static let kind = "com.roadsandrunes.watch.nextUp"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NextUpProvider()) { entry in
            NextUpComplicationView(face: entry.face)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Next up")
        .description("Your streak and today's bounty.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct NextUpComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let face: WatchComplication

    var body: some View {
        switch family {
        case .accessoryCorner:
            corner
        case .accessoryInline:
            Text(face.inlineText)
        case .accessoryRectangular:
            rectangular
        default:
            circular
        }
    }

    /// The quarry's or the bounty's mark; the streak's number when there is neither.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let mark = face.mark {
                ComplicationMark(mark: mark)
                    .padding(7)
            } else {
                VStack(spacing: -2) {
                    Text("\(face.streakDays)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text("streak")
                        .font(.system(size: 9, weight: .semibold))
                        .textCase(.uppercase)
                }
                .widgetAccentable()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(face.mark.map { $0.isQuarry ? $0.name : "Bounty: \($0.name)" } ?? face.streakLine)
    }

    /// The streak, with its line round the corner.
    private var corner: some View {
        Text("\(face.streakDays)")
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .widgetAccentable()
            .widgetLabel {
                Text(face.streakLine)
            }
            .accessibilityLabel(face.streakLine)
    }

    /// The bounty and how far; the quarry while a journey is under way; else the streak.
    private var rectangular: some View {
        HStack(spacing: 8) {
            if let mark = face.mark {
                ComplicationMark(mark: mark)
                    .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(heading)
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .widgetAccentable()
                Text(face.mark?.name ?? face.streakLine)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var heading: String {
        guard let mark = face.mark else { return "Roads & Runes" }
        return mark.isQuarry ? "On your journey" : "Bounty"
    }

    private var detail: String? {
        guard let mark = face.mark else { return nil }
        if mark.isQuarry { return face.streakDays > 0 ? face.streakLine : nil }
        return [face.bountyDistanceLine, face.streakDays > 0 ? "Streak \(face.streakDays)" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// A mark on the watch face. Complications are small, so it is the silhouette
/// (`MarkRenderer.detailSize`): drawn whole in full colour, and as the bare
/// glyph where the face tints it.
struct ComplicationMark: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    let mark: WatchComplication.Mark

    private var icon: GameIcon {
        if let name = mark.icon, let icon = GameIcon(rawValue: name) { return icon }
        if let species = mark.speciesId, !species.isEmpty { return GameIcon.forSpecies(species) }
        return .dragonHead
    }

    var body: some View {
        if renderingMode == .fullColor {
            // The quarry in terracotta; the bounty, and a legend (0.8.0), in gold.
            MarkView(.token(icon, ring: mark.isQuarry && !mark.isLegend ? .terracotta : .gold), palette: .watch)
        } else {
            IconShape(icon)
                .widgetAccentable()
        }
    }
}
