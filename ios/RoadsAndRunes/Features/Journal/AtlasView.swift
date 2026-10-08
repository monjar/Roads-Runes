import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The Atlas (0.9.0), the Journal's map grown up: every journey of the year on
/// one map (on parchment when that map is on), a calendar with the days you went
/// out marked, and your year in plain rows.
@MainActor
@Observable
final class AtlasModel {
    private(set) var atlas: Atlas?
    private(set) var loading = false
    var error: String?
    var year: Int
    var month: AtlasCalendar.Month
    private let api: any RoadsAndRunesAPI

    init(api: any RoadsAndRunesAPI, today: Date = Date(), calendar: Calendar = .current) {
        self.api = api
        let parts = calendar.dateComponents([.year, .month], from: today)
        let current = parts.year ?? 2026
        year = current
        thisYear = current
        month = AtlasCalendar.Month(year: current, month: parts.month ?? 1)
    }

    let thisYear: Int

    func load() async {
        loading = true
        defer { loading = false }
        do {
            atlas = try await api.atlas(year: year)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func show(year: Int) async {
        guard year <= thisYear, year != self.year else { return }
        self.year = year
        month = AtlasCalendar.Month(year: year, month: year == thisYear ? month.month : 12)
        atlas = nil
        await load()
    }

    func showMonth(_ next: AtlasCalendar.Month) async {
        month = next
        if next.year != year { await show(year: next.year) }
    }

    var paths: [[Coordinate]] { atlas?.traces.map(\.path).filter { $0.count >= 2 } ?? [] }

    /// Where every line of the year fits, for the camera.
    var fit: [Coordinate] {
        let all = paths.flatMap { $0 }
        guard let first = all.first else { return [] }
        var box = BoundingBox(minLat: first.latitude, minLon: first.longitude, maxLat: first.latitude, maxLon: first.longitude)
        for point in all {
            box = BoundingBox(minLat: min(box.minLat, point.latitude), minLon: min(box.minLon, point.longitude),
                              maxLat: max(box.maxLat, point.latitude), maxLon: max(box.maxLon, point.longitude))
        }
        return [Coordinate(latitude: box.minLat, longitude: box.minLon), Coordinate(latitude: box.maxLat, longitude: box.maxLon)]
    }
}

struct AtlasSection: View {
    @Environment(AppContainer.self) private var container
    let journal: JournalViewModel
    @State private var model: AtlasModel?
    @State private var openDay: String?
    @State private var camera: MapCamera?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let model {
                if let error = model.error { ErrorLine(text: error) }
                yearPicker(model)
                mapCard(model)
                calendar(model)
                yourYear(model)
            } else {
                ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal.atlas")
        .task {
            if model == nil { model = AtlasModel(api: container.api) }
            await model?.load()
            fitCamera()
        }
        .onChange(of: model?.year) { _, _ in fitCamera() }
        .sheet(item: Binding(get: { openDay.map(DayKey.init) }, set: { openDay = $0?.id })) { day in
            AtlasDaySheet(day: day.id, traces: model?.atlas?.traces(on: day.id) ?? [], adventures: adventures(on: day.id),
                          units: journal.units, ink: inkColor)
                .presentationDetents([.medium, .large])
        }
    }

    private struct DayKey: Identifiable { let id: String }

    private var inkColor: UIColor { LookStyle.routeColor(container.session.inventory) }

    private func fitCamera() {
        guard let fit = model?.fit, fit.count >= 2 else { return }
        camera = MapCamera(fit: fit, padding: UIEdgeInsets(top: 40, left: 30, bottom: 40, right: 30))
    }

    private func adventures(on day: String) -> [AdventureEntry] {
        journal.adventures.filter { Self.dayKey($0.ride.startedAt) == day }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Parts

    private func yearPicker(_ model: AtlasModel) -> some View {
        HStack(spacing: 12) {
            Button { Task { await model.show(year: model.year - 1) } } label: {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Year before")
            .accessibilityIdentifier("atlas.yearBefore")
            Text("Your \(String(model.year))").font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                .accessibilityIdentifier("atlas.year")
            Button { Task { await model.show(year: model.year + 1) } } label: {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.pressable)
            .disabled(model.year >= model.thisYear)
            .opacity(model.year >= model.thisYear ? 0.3 : 1)
            .accessibilityLabel("Year after")
            .accessibilityIdentifier("atlas.yearAfter")
            Spacer()
            if model.loading { ProgressView().tint(Theme.Colors.terracotta) }
        }
        .foregroundStyle(Theme.Colors.ink)
    }

    private func mapCard(_ model: AtlasModel) -> some View {
        ZStack(alignment: .bottomLeading) {
            MapLibreView(
                styleURL: styleURL,
                center: model.fit.first ?? journal.mapCenter ?? SampleData.origin,
                zoom: 11.5,
                cells: journal.cells,
                inkWash: journal.inkWash,
                route: [],
                markers: journal.cutMarkers,
                routeColor: inkColor,
                traces: model.paths,
                interactive: false,
                camera: camera
            )
            if let atlas = model.atlas {
                StatusPill(text: atlas.traces.isEmpty ? "No journeys this year yet" : "\(atlas.traces.count) \(atlas.traces.count == 1 ? "journey" : "journeys") on the map")
                    .padding(12)
            }
        }
        .frame(height: 360)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityIdentifier("atlas.map")
    }

    /// The parchment map when it is on, else the usual Outdoors map.
    private var styleURL: URL {
        if container.session.isEnabled(FeatureFlag.parchmentMap), let parchment = Config.parchmentStyleURL { return parchment }
        return Config.mapStyleURL(for: .adventure)
    }

    // MARK: The calendar

    private static let weekdays = ["M", "T", "W", "T", "F", "S", "S"]

    private func calendar(_ model: AtlasModel) -> some View {
        let days = model.atlas?.daysByKey ?? [:]
        let month = model.month
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(monthTitle(month)).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                    .accessibilityIdentifier("atlas.month")
                Spacer()
                Button { Task { await model.showMonth(month.previous) } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold)).frame(width: 32, height: 32)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Month before")
                .accessibilityIdentifier("atlas.monthBefore")
                Button { Task { await model.showMonth(month.next) } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).frame(width: 32, height: 32)
                }
                .buttonStyle(.pressable)
                .disabled(month.year >= model.thisYear && month.next.year > model.thisYear)
                .accessibilityLabel("Month after")
                .accessibilityIdentifier("atlas.monthAfter")
            }
            .foregroundStyle(Theme.Colors.ink)
            HStack(spacing: 0) {
                ForEach(Array(Self.weekdays.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(Theme.Typography.eyebrow).foregroundStyle(Theme.Colors.muted).frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(AtlasCalendar.grid(month).enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day.map { AtlasCalendar.key(month, day: $0) }, number: day, days: days)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            let count = days.filter { $0.key.hasPrefix(String(format: "%04d-%02d", month.year, month.month)) }.count
            Text(count == 0 ? "No journeys this month." : "Out on \(count) \(count == 1 ? "day" : "days") this month. Tap a day to see it.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("atlas.calendar")
    }

    @ViewBuilder
    private func dayCell(_ key: String?, number: Int?, days: [String: AtlasDay]) -> some View {
        if let key, let number {
            let out = days[key]
            Button { if out != nil { openDay = key } } label: {
                ZStack {
                    if let out {
                        Circle().fill(out.journeys > 1 ? Theme.Colors.terracotta : Theme.Colors.terracottaLight)
                            .frame(width: 32, height: 32)
                    }
                    Text("\(number)")
                        .font(Theme.Typography.text(13, out != nil ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(out != nil ? Theme.Colors.cream : Theme.Colors.inkSoft)
                }
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(out == nil)
            .accessibilityLabel(out.map { "\(key), \($0.journeys) \($0.journeys == 1 ? "journey" : "journeys")" } ?? key)
            .accessibilityIdentifier(out != nil ? "atlas.day.\(key)" : "atlas.empty.\(key)")
        } else {
            Color.clear.frame(height: 36)
        }
    }

    private func monthTitle(_ month: AtlasCalendar.Month) -> String {
        var parts = DateComponents()
        parts.year = month.year
        parts.month = month.month
        parts.day = 1
        let date = Calendar.current.date(from: parts) ?? Date()
        return date.formatted(.dateTime.month(.wide).year())
    }

    // MARK: Your year

    @ViewBuilder
    private func yourYear(_ model: AtlasModel) -> some View {
        if let year = model.atlas?.year {
            let f = UnitFormatter(units: journal.units)
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Your year", subtitle: String(model.year))
                VStack(spacing: 0) {
                    yearRow("Journeys", "\(year.journeys)")
                    yearRow("Distance", f.distance(meters: year.distanceMeters))
                    yearRow("New tiles explored", "\(year.newTiles)")
                    yearRow("Creatures defeated", "\(year.creaturesDefeated)")
                    yearRow("Legends defeated", "\(year.legendsDefeated)")
                    yearRow("Rune rides", "\(year.runesCut)")
                    yearRow("Districts yours", "\(year.districtsYours)", last: year.deedsReached.isEmpty)
                    if !year.deedsReached.isEmpty {
                        yearRow("Deeds reached", year.deedsReached.joined(separator: ", "), last: true)
                    }
                }
                .padding(.horizontal, 14)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .accessibilityIdentifier("atlas.yourYear")
                if !year.firsts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "Firsts", color: Theme.Colors.sageDeep)
                        ForEach(Array(year.firsts.enumerated()), id: \.offset) { _, first in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                MarkView(.icon(.star, spot: .gold)).frame(width: 14, height: 14)
                                Text(first.text).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if let day = first.day { Text(Self.shortDay(day)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted) }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("atlas.firsts")
                }
            }
        }
    }

    private func yearRow(_ label: String, _ value: String, last: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
            Spacer(minLength: 8)
            Text(value).font(Theme.Typography.text(14, .bold).monospacedDigit()).foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.Colors.track).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    /// "3 Oct" from "2026-10-03".
    static func shortDay(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        guard let date = Calendar.current.date(from: components) else { return key }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// One day of the calendar: its lines on the map and the journeys made.
struct AtlasDaySheet: View {
    let day: String
    let traces: [AtlasTrace]
    let adventures: [AdventureEntry]
    let units: Units
    let ink: UIColor

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    SheetHandle().frame(maxWidth: .infinity)
                    Text(title).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                    let paths = traces.map(\.path).filter { $0.count >= 2 }
                    if !paths.isEmpty {
                        MapLibreView(styleURL: Config.mapStyleURL(for: .adventure), center: paths.first?.first, zoom: 12,
                                     route: [], routeColor: ink, traces: paths, interactive: false,
                                     camera: MapCamera(fit: paths.flatMap { $0 }, padding: UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)))
                            .frame(height: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    if adventures.isEmpty {
                        Text("\(traces.count) \(traces.count == 1 ? "journey" : "journeys") this day.")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    ForEach(adventures) { entry in
                        NavigationLink { AdventureDetailView(entry: entry) } label: { AdventureRow(entry: entry, units: units) }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("atlas.dayJourney")
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .background(Theme.Colors.cream)
            .toolbar(.hidden, for: .navigationBar)
        }
        .accessibilityIdentifier("atlas.daySheet")
    }

    private var title: String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? day
    }
}
