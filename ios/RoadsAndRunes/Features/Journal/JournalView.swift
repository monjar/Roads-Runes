import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class JournalViewModel {
    private(set) var adventures: [AdventureEntry] = []
    private(set) var discoveries: [UserDiscovery] = []
    private(set) var stats: ExplorationStats?
    private(set) var cells: [CellRender] = []
    /// The fog as ink (0.7.0): the paper over ground not yet read, with the read ground cut out.
    private(set) var inkWash: [[Coordinate]] = []
    /// Where runes were cut, drawn on the map (0.7.0).
    private(set) var cuts: [RuneCutInfo] = []
    private(set) var mapCenter: Coordinate?
    /// The world's pages and what this player has met; nil while loading, or with the codex off.
    private(set) var codex: Codex?
    var error: String?
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }
    var units: Units { container.session.units }

    /// Takes an adventure out of the journal. The server discards the ride, so
    /// its distance and speeds leave the stats with it; XP already earned stays.
    func delete(_ entry: AdventureEntry) async -> Bool {
        do {
            try await container.api.deleteRide(id: entry.ride.id)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        adventures.removeAll { $0.id == entry.id }
        stats = try? await container.api.journalStats()
        return true
    }

    func load() async {
        do {
            adventures = try await container.api.adventures().items
            discoveries = try await container.api.myDiscoveries().items
            stats = try await container.api.journalStats()
            error = nil
            if container.session.isEnabled("codex") {
                codex = try? await container.api.codex()
            }
        } catch {
            self.error = error.localizedDescription
        }
        let center = container.location.lastFix?.coordinate ?? adventures.first?.quest?.origin ?? SampleData.origin
        mapCenter = center
        cuts = (try? await container.api.runeCuts()) ?? []
        // The read ground, whether or not the World draws the fog, as one wash.
        let dLat = 8000 / 111_195.0, dLon = 8000 / (111_195.0 * max(0.2, cos(center.latitude * .pi / 180)))
        let box = BoundingBox(minLat: center.latitude - dLat, minLon: center.longitude - dLon,
                              maxLat: center.latitude + dLat, maxLon: center.longitude + dLon)
        if let read = try? await container.api.exploration(in: box) {
            let outlines = container.cellIndexing.outlines(of: read.cells.map(\.h3))
            inkWash = InkFog.wash(bounds: InkFog.padded(box), outlines: outlines)
            cells = []
        } else if let world = try? await container.api.world(center: center, radiusMeters: 8000) {
            cells = FogGrid(indexing: container.cellIndexing).render(serverCells: world.cells, localStates: [:])
        }
    }

    /// A mark where each rune ride was made: "Raido rune ride, by the pond".
    var cutMarkers: [MapMarker] {
        cuts.map { cut in
            MapMarker(id: "cut-\(cut.id)", coordinate: cut.coordinate, kind: .collectable,
                      title: cut.placeName.map { "\(cut.name) rune ride, by \($0)" } ?? "\(cut.name) rune ride",
                      mark: .rune(cut.runeId))
        }
    }

    struct DiscoveryItem: Identifiable, Hashable {
        let summary: DiscoverySummary
        let date: Date?
        let questTitle: String?
        var id: UUID { summary.id }
        var group: String { DiscoveryIcon.group(for: summary.category) }
    }

    /// Discoveries with names and kinds, collected from the adventures that found them.
    var discoveryItems: [DiscoveryItem] {
        var seen: Set<UUID> = []
        var items: [DiscoveryItem] = []
        let dates = Dictionary(discoveries.map { ($0.discoveryId, $0.discoveredAt) }, uniquingKeysWith: { a, _ in a })
        for entry in adventures {
            for summary in entry.discoveries where !seen.contains(summary.id) {
                seen.insert(summary.id)
                items.append(DiscoveryItem(summary: summary, date: dates[summary.id] ?? summary.discoveredAt ?? entry.ride.startedAt, questTitle: entry.quest?.title))
            }
        }
        return items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    struct MonthSummary {
        let title: String
        let adventures: Int
        let newTerritoryMeters: Double
        let discoveries: Int
        let quests: Int
        let climbMeters: Double
    }

    var latestMonth: MonthSummary? {
        guard let first = adventures.max(by: { $0.ride.startedAt < $1.ride.startedAt }) else { return nil }
        let calendar = Calendar.current
        let key = calendar.dateComponents([.year, .month], from: first.ride.startedAt)
        let inMonth = adventures.filter { calendar.dateComponents([.year, .month], from: $0.ride.startedAt) == key }
        return MonthSummary(
            title: first.ride.startedAt.formatted(.dateTime.month(.wide)),
            adventures: inMonth.count,
            newTerritoryMeters: inMonth.reduce(0) { $0 + $1.newTerritoryMeters },
            discoveries: inMonth.reduce(0) { $0 + $1.discoveries.count },
            quests: inMonth.filter { $0.quest != nil }.count,
            climbMeters: inMonth.reduce(0) { $0 + $1.ride.elevationGainMeters }
        )
    }
}

enum JournalSection: Int, CaseIterable, Hashable {
    case adventures, discoveries, map, stats

    /// The second segment is the codex (docs/WORLD.md) when it is on: the places
    /// found are its last chapter.
    func title(codex: Bool) -> String {
        switch self {
        case .adventures: return "Journeys"
        case .discoveries: return codex ? "Codex" : "Places"
        case .map: return "Map"
        case .stats: return "Stats"
        }
    }
}

/// Journal (design 14a/14b): the month in exploration terms, completed quests as
/// entries, the explored world as the collection's cover. Statistics is a tab,
/// not the headline (spec §41–42).
struct JournalView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: JournalViewModel?
    @State private var section: JournalSection = .adventures
    @State private var filter: String? = nil
    @State private var deleting: AdventureEntry?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Journal").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                        Spacer()
                        if let stats = model?.stats {
                            Text("\(exploredArea(stats)) explored · \(stats.discoveriesFound) \(stats.discoveriesFound == 1 ? "place" : "places") found").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    SegmentedPill(options: JournalSection.allCases, title: { $0.title(codex: codexOn) }, selection: $section)
                    if let model {
                        if let error = model.error { ErrorLine(text: error) }
                        switch section {
                        case .adventures: adventures(model)
                        case .discoveries:
                            if codexOn {
                                CodexBrowser(codex: model.codex, showWants: container.session.isEnabled("effort_combat")) {
                                    discoveries(model)
                                }
                            } else {
                                discoveries(model)
                            }
                        case .map: mapSection(model)
                        case .stats: StatsView(stats: model.stats, units: model.units)
                        }
                    } else {
                        ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, Theme.Layout.tabBarClearance)
            }
            .background(Theme.Colors.cream)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model?.load() }
            .confirmationDialog(
                "Delete this journey?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { entry in
                Button("Delete journey", role: .destructive) { Task { _ = await model?.delete(entry) } }
                Button("Keep journey", role: .cancel) {}
            } message: { _ in
                Text("It's removed from your Journal and stats. The XP you earned stays.")
            }
        }
        .task {
            if model == nil { model = JournalViewModel(container: container) }
            await model?.load()
        }
        .onChange(of: container.sync.latestSummary) { _, summary in
            if summary == nil { Task { await model?.load() } }
        }
    }

    private var codexOn: Bool { container.session.isEnabled("codex") }

    private func exploredArea(_ stats: ExplorationStats) -> String {
        let area = Double(stats.cellsVisited) * 0.1053
        return area >= 10 ? "\(Int(area.rounded())) km²" : String(format: "%.1f km²", area)
    }

    // MARK: Adventures (14a)

    @ViewBuilder
    private func adventures(_ model: JournalViewModel) -> some View {
        let f = UnitFormatter(units: model.units)
        if let month = model.latestMonth {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(month.title).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    Text("\(month.adventures) \(month.adventures == 1 ? "journey" : "journeys")").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
                HStack(spacing: 16) {
                    fact(f.distance(meters: month.newTerritoryMeters), "newly explored")
                    fact("\(month.discoveries)", month.discoveries == 1 ? "place" : "places")
                    fact("\(month.quests)", "quests")
                    fact(f.elevation(meters: month.climbMeters), "")
                }
            }
            .card()
        }
        if model.adventures.isEmpty {
            EmptyState(icon: .openBook, title: LoreCopy.emptyJournalTitle, message: LoreCopy.emptyJournalMessage)
        }
        ForEach(model.adventures) { entry in
            NavigationLink { AdventureDetailView(entry: entry, onDelete: { await model.delete(entry) }) } label: {
                AdventureRow(entry: entry, units: model.units)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("adventureRow")
            .contextMenu {
                Button(role: .destructive) { deleting = entry } label: { Label("Delete journey", systemImage: "trash") }
            }
        }
    }

    private func fact(_ value: String, _ label: String) -> some View {
        (Text(value).font(Theme.Typography.text(14, .bold)) + Text(label.isEmpty ? "" : " \(label)").font(Theme.Typography.text(14)))
            .foregroundStyle(Theme.Colors.ink)
            .lineLimit(1)
    }

    // MARK: Places found (14b)

    @ViewBuilder
    private func discoveries(_ model: JournalViewModel) -> some View {
        let items = model.discoveryItems
        let groups = ["Natural", "Historical", "Cultural", "Cycling"].filter { g in items.contains { $0.group == g } }
        mapCard(model, height: 210)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(text: "All \(items.count)", selected: filter == nil) { filter = nil }
                ForEach(groups, id: \.self) { group in
                    FilterChip(text: "\(group) \(items.filter { $0.group == group }.count)", selected: filter == group) { filter = group }
                }
            }
        }
        let visible = items.filter { filter == nil || $0.group == filter }
        if visible.isEmpty {
            EmptyState(icon: .star, title: "No places found yet", message: "Pass landmarks, parks, pubs and viewpoints to add them here.")
        }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(visible) { item in
                NavigationLink { DiscoveryDetailView(discoveryId: item.id) } label: {
                    DiscoveryTile(name: item.summary.name, category: item.summary.category, subtitle: subtitle(for: item))
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func subtitle(for item: JournalViewModel.DiscoveryItem) -> String {
        var parts = [item.group]
        if let date = item.date { parts.append(date.formatted(.dateTime.day().month(.abbreviated))) }
        if let quest = item.questTitle { parts.append(quest) }
        return parts.joined(separator: " · ")
    }

    // MARK: Map

    @ViewBuilder
    private func mapSection(_ model: JournalViewModel) -> some View {
        mapCard(model, height: 360)
        if let stats = model.stats {
            HStack(spacing: 8) {
                FactTile(value: "\(stats.cellsVisited)", label: "Tiles visited")
                FactTile(value: "\(stats.cellsExplored)", label: "Fully explored")
                FactTile(value: "\(stats.cellsDiscovered ?? 0)", label: "Shown by quests")
            }
            Text("Blank paper is the fog: unexplored. Go there to fill in the map.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        }
    }

    private func mapCard(_ model: JournalViewModel, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            MapLibreView(
                styleURL: Config.mapStyleURL(for: .adventure),
                center: model.mapCenter ?? SampleData.origin,
                zoom: 11.5,
                cells: model.cells,
                inkWash: model.inkWash,
                route: [],
                markers: model.cutMarkers
            )
            .allowsHitTesting(false)
            if let stats = model.stats {
                StatusPill(text: "\(stats.cellsVisited) tiles · \(stats.cellsExplored) fully explored").padding(12)
            }
        }
        .frame(height: height)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// Journal entry (design 14a): ink thumbnail, Caprasimo title, XP, one line of facts.
struct AdventureRow: View {
    let entry: AdventureEntry
    let units: Units

    var body: some View {
        let f = UnitFormatter(units: units)
        HStack(spacing: 12) {
            // A quest's crest, or for a free journey what it was: a bike, a run, a walk.
            Group {
                if let quest = entry.quest {
                    ClassEmblem(characterClass: quest.characterClass, size: 64)
                } else {
                    MarkView(.rider(entry.ride.activity?.rawValue ?? "RIDE")).frame(width: 64, height: 64)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.quest?.title ?? entry.ride.title ?? LoreCopy.free(entry.ride.activity)).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text("+\(entry.xpAwarded) XP")
                        .font(Theme.Typography.captionStrong)
                        .foregroundStyle(entry.quest.map { ClassStyle.textColor($0.characterClass) } ?? Theme.Colors.sageDeep)
                }
                Text(meta(f)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                // The first line of the entry, for a journal that reads like one.
                if let written = entry.entryToRead, let first = written.split(separator: ".").first, !first.isEmpty {
                    Text(first + ".").font(Theme.Typography.caption).italic().foregroundStyle(Theme.Colors.inkSoft).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private func meta(_ f: UnitFormatter) -> String {
        var parts = [entry.ride.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), f.distance(meters: entry.ride.distanceMeters)]
        if !entry.discoveries.isEmpty { parts.append("\(entry.discoveries.count) \(entry.discoveries.count == 1 ? "place" : "places")") }
        if entry.newTerritoryMeters > 0 { parts.append("\(f.distance(meters: entry.newTerritoryMeters)) explored") }
        return parts.joined(separator: " · ")
    }
}

/// Exploration-first statistics (spec §42); speed stays secondary.
struct StatsView: View {
    let stats: ExplorationStats?
    let units: Units

    var body: some View {
        if let stats {
            let f = UnitFormatter(units: units)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                FactTile(value: f.distance(meters: stats.newTerritoryKm * 1000), label: "Newly explored")
                FactTile(value: f.distance(meters: stats.uniqueRoadsKm * 1000), label: "Unique roads")
                FactTile(value: "\(stats.regionsVisited)", label: "Regions visited")
                FactTile(value: "\(stats.questsCompleted)", label: "Quests completed")
                FactTile(value: "\(stats.discoveriesFound)", label: "Places found")
                FactTile(value: "\(stats.storyQuestsCompleted)", label: "Story quests")
                FactTile(value: f.distance(meters: stats.totalDistanceMeters), label: "Total distance")
                FactTile(value: f.elevation(meters: stats.totalElevationMeters), label: "Total climb")
            }
            if let avg = stats.averageSpeedMps {
                HStack(spacing: 8) {
                    FactTile(value: f.speed(metersPerSecond: avg), label: "Average speed", valueColor: Theme.Colors.muted)
                    if let max = stats.maxSpeedMps { FactTile(value: f.speed(metersPerSecond: max), label: "Max speed", valueColor: Theme.Colors.muted) }
                }
                .opacity(0.8)
            }
        } else {
            ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
        }
    }
}

struct AdventureDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let entry: AdventureEntry
    /// Removes the adventure; the screen closes when it succeeds.
    var onDelete: (() async -> Bool)? = nil
    @State private var geometry: RideGeometry?
    @State private var notes: String = ""
    @State private var confirmingDelete = false
    @State private var strava: StravaStatus?
    @State private var stravaUpload: String?  // the ride's status, refreshed after a retry
    @State private var stravaError: String?
    @State private var stravaBusy = false

    /// Where this ride stands with Strava: sent (with a link once Strava has made
    /// the activity), failed (with the reason and a retry), or not sent (with the
    /// upload, when connected). Nothing at all when Strava is not connected.
    @ViewBuilder
    private var stravaRow: some View {
        let status = stravaUpload ?? entry.ride.stravaUploadStatus
        if status == "UPLOADED", let url = (refreshed ?? entry.ride).stravaURL {
            Link(destination: url) { Label("Open in Strava", systemImage: "arrow.up.right.square") }.buttonStyle(.surfacePill)
        } else if status == "UPLOADED" || status == "QUEUED" {
            Label(status == "QUEUED" ? "Sending to Strava…" : "On Strava", systemImage: "checkmark.circle")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
        } else if status == "FAILED" {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't send to Strava. \(stravaError ?? entry.ride.stravaError ?? "Try again.")")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
                Button(stravaBusy ? "Retrying…" : "Try again") { uploadToStrava() }.buttonStyle(.surfacePill).disabled(stravaBusy)
            }
        } else if strava?.connected == true {
            Button(stravaBusy ? "Sending…" : "Upload to Strava") { uploadToStrava() }.buttonStyle(.surfacePill).disabled(stravaBusy)
        }
    }

    private func uploadToStrava() {
        stravaBusy = true
        Task {
            do {
                _ = try await container.api.uploadRideToStrava(rideId: entry.ride.id)
                stravaUpload = "QUEUED"
                stravaError = nil
                // The job runs in the background; look again in a few seconds for the link.
                try? await Task.sleep(for: .seconds(8))
                if let ride = try? await container.api.ride(id: entry.ride.id) {
                    stravaUpload = ride.stravaUploadStatus
                    stravaError = ride.stravaError
                    refreshed = ride
                }
            } catch {
                stravaUpload = "FAILED"
                stravaError = error.localizedDescription
            }
            stravaBusy = false
        }
    }
    @State private var refreshed: Ride?
    @State private var reckoning: AdventureSummary?
    @State private var loadingReckoning = false

    var body: some View {
        let f = UnitFormatter(units: container.session.units)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IconCircleButton(symbol: "chevron.left", background: Theme.Colors.surface) { dismiss() }
                    Spacer()
                    if let quest = entry.quest {
                        Eyebrow(text: "\(ClassStyle.name(quest.characterClass)) quest · \(entry.ride.startedAt.formatted(date: .abbreviated, time: .omitted))", color: ClassStyle.textColor(quest.characterClass))
                    } else {
                        Eyebrow(text: entry.ride.startedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if onDelete != nil {
                        IconCircleButton(symbol: "trash", background: Theme.Colors.surface) { confirmingDelete = true }
                    }
                }
                HStack(alignment: .bottom) {
                    Text(entry.quest?.title ?? entry.ride.title ?? LoreCopy.free(entry.ride.activity)).font(Theme.Typography.voice(28, relativeTo: .title)).foregroundStyle(Theme.Colors.ink)
                    Spacer(minLength: 8)
                    Text("+\(entry.xpAwarded) XP").font(Theme.Typography.text(22, .bold)).foregroundStyle(Theme.Colors.sageDeep)
                }
                // The model's lines when it wrote some (0.7.2), else the composed entry.
                if let written = entry.entryToRead, !written.isEmpty {
                    Text(written).font(Theme.Typography.text(15)).italic().foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("journal.entry")
                }
                MapLibreView(styleURL: Config.mapStyleURL(for: .adventure), center: geometry?.path.first ?? entry.quest?.origin, zoom: 12, cells: [], route: geometry?.path ?? [], markers: markers)
                    .frame(height: 220)
                    .background(Theme.Colors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                HStack(spacing: 8) {
                    FactTile(value: f.distance(meters: entry.ride.distanceMeters), label: "Distance")
                    FactTile(value: f.duration(seconds: Double(entry.ride.durationSeconds)), label: "Time")
                    FactTile(value: f.elevation(meters: entry.ride.elevationGainMeters), label: "Climbed")
                    FactTile(value: f.distance(meters: entry.newTerritoryMeters), label: "Explored", valueColor: Theme.Colors.sageDeep)
                }
                if !entry.discoveries.isEmpty {
                    SectionHeader(title: "Places found", subtitle: "\(entry.discoveries.count)")
                    ForEach(entry.discoveries) { discovery in
                        NavigationLink { DiscoveryDetailView(discoveryId: discovery.id) } label: {
                            DiscoveryCard(discovery: discovery, subtitle: DiscoveryIcon.group(for: discovery.category))
                        }
                        .buttonStyle(.pressable)
                    }
                }
                SectionHeader(title: "Notes")
                TextField("What made this \(LoreCopy.journey(entry.ride.activity)) memorable?", text: $notes, axis: .vertical)
                    .font(Theme.Typography.text(15))
                    .lineLimit(3...6)
                    .padding(14)
                    .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                // The summary was shown once, at the end of the ride, and never again.
                Button {
                    loadingReckoning = true
                    Task {
                        reckoning = try? await container.api.rideSummary(id: entry.ride.id)
                        loadingReckoning = false
                    }
                } label: {
                    Label(loadingReckoning ? "Loading…" : "See journey's end", systemImage: "scroll")
                }
                .buttonStyle(.surfacePill)
                .disabled(loadingReckoning)
                .accessibilityIdentifier("journal.reckoning")
                HStack(spacing: 8) {
                    Button("Save notes") { Task { _ = try? await container.api.updateRide(id: entry.ride.id, RidePatch(notes: notes)) } }.buttonStyle(.inkPill)
                    ShareLink(item: container.api.rideExportURL(id: entry.ride.id, format: .gpx)) { Label("Export GPX", systemImage: "square.and.arrow.up") }.buttonStyle(.surfacePill)
                    stravaRow
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Delete this journey?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete journey", role: .destructive) {
                Task {
                    if let onDelete, await onDelete() { dismiss() }
                }
            }
            Button("Keep journey", role: .cancel) {}
        } message: {
            Text("It's removed from your Journal and stats. The XP you earned stays.")
        }
        .fullScreenCover(item: $reckoning) { summary in
            AdventureSummaryView(summary: summary, units: container.session.units, animated: false) { reckoning = nil }
        }
        .task {
            notes = entry.notes ?? ""
            geometry = try? await container.api.rideGeometry(id: entry.ride.id)
            strava = try? await container.api.stravaStatus()
        }
    }

    private var markers: [MapMarker] {
        entry.discoveries.map { MapMarker(id: $0.id.uuidString, coordinate: $0.coordinate, kind: .discovery, title: $0.name) }
    }
}

struct DiscoveryDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let discoveryId: UUID
    @State private var discovery: Discovery?
    @State private var note = ""
    @State private var rating = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    IconCircleButton(symbol: "chevron.left", background: Theme.Colors.surface) { dismiss() }
                    Spacer()
                }
                if let discovery {
                    HStack(spacing: 14) {
                        MarkView(DiscoveryIcon.mark(for: discovery.category))
                        .frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(discovery.name).font(Theme.Typography.voice(26, relativeTo: .title)).foregroundStyle(Theme.Colors.ink)
                            Text(DiscoveryIcon.group(for: discovery.category)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    if let description = discovery.description {
                        Text(description).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft).lineSpacing(3)
                    }
                    let marker = MapMarker(id: discovery.id.uuidString, coordinate: discovery.coordinate, kind: .discovery, title: discovery.name)
                    MapLibreView(styleURL: Config.mapStyleURL(for: .adventure), center: discovery.coordinate, zoom: 14, cells: [], route: [], markers: [marker])
                        .frame(height: 160)
                        .background(Theme.Colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .allowsHitTesting(false)
                    SectionHeader(title: "Your note")
                    TextField("Stop safely before writing.", text: $note, axis: .vertical)
                        .font(Theme.Typography.text(15))
                        .lineLimit(3...6)
                        .padding(14)
                        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    HStack(spacing: 6) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .font(.system(size: 20))
                                .foregroundStyle(Theme.Colors.terracotta)
                                .onTapGesture { rating = star }
                        }
                    }
                    Button("Save note") {
                        Task { _ = try? await container.api.updateUserDiscovery(id: discoveryId, UserDiscoveryIn(note: note, rating: rating == 0 ? nil : rating)) }
                    }
                    .buttonStyle(.inkPill)
                } else {
                    ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            discovery = try? await container.api.discovery(id: discoveryId)
            note = discovery?.userDiscovery?.note ?? ""
            rating = discovery?.userDiscovery?.rating ?? 0
        }
    }
}
