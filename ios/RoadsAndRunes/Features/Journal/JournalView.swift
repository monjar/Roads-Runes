import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class JournalViewModel {
    private(set) var adventures: [AdventureEntry] = []
    private(set) var discoveries: [UserDiscovery] = []
    private(set) var stats: ExplorationStats?
    var error: String?
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }
    var units: Units { container.session.units }

    func load() async {
        do {
            adventures = try await container.api.adventures().items
            discoveries = try await container.api.myDiscoveries().items
            stats = try await container.api.journalStats()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct JournalView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: JournalViewModel?
    @State private var section = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    Text("Adventures").tag(0); Text("Discoveries").tag(1); Text("World").tag(2); Text("Statistics").tag(3)
                }
                .pickerStyle(.segmented).padding(Theme.Spacing.md)
                ScrollView {
                    if let model {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            switch section {
                            case 0: adventures(model)
                            case 1: discoveries(model)
                            case 2: WorldStatsView(stats: model.stats, units: model.units)
                            default: StatsView(stats: model.stats, units: model.units)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                    }
                }
            }
            .background(Theme.Colors.parchment)
            .navigationTitle("Journal")
            .refreshable { await model?.load() }
        }
        .task {
            if model == nil { model = JournalViewModel(container: container) }
            await model?.load()
        }
        .onChange(of: container.sync.latestSummary) { _, summary in
            if summary == nil { Task { await model?.load() } }
        }
    }

    @ViewBuilder
    private func adventures(_ model: JournalViewModel) -> some View {
        if model.adventures.isEmpty {
            EmptyState(icon: "book", title: "No adventures yet", message: "Your completed rides, quests and discoveries will be recorded here.")
        }
        ForEach(model.adventures) { entry in
            NavigationLink { AdventureDetailView(entry: entry) } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack {
                        Text(entry.quest?.title ?? entry.ride.title ?? "Free ride").font(Theme.Typography.heading)
                        Spacer()
                        Text("+\(entry.xpAwarded) XP").font(Theme.Typography.heading).foregroundStyle(Theme.Colors.moss)
                    }
                    let f = UnitFormatter(units: model.units)
                    Text("\(entry.ride.startedAt.formatted(date: .abbreviated, time: .omitted)) · \(f.distance(meters: entry.ride.distanceMeters)) · \(f.elevation(meters: entry.ride.elevationGainMeters)) · \(entry.discoveries.count) discoveries · \(f.distance(meters: entry.newTerritoryMeters)) new")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func discoveries(_ model: JournalViewModel) -> some View {
        if model.discoveries.isEmpty {
            EmptyState(icon: "sparkles", title: "Nothing discovered yet", message: "Ride past landmarks, parks, cafés and viewpoints to add them to your library.")
        }
        ForEach(model.discoveries) { item in
            NavigationLink { DiscoveryDetailView(discoveryId: item.discoveryId) } label: {
                HStack {
                    Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.Colors.river)
                    VStack(alignment: .leading) {
                        Text(item.note?.isEmpty == false ? item.note! : "Discovered \(item.discoveredAt.formatted(date: .abbreviated, time: .omitted))").font(Theme.Typography.body).lineLimit(1)
                        if let rating = item.rating { Text(String(repeating: "★", count: rating)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.rune) }
                    }
                    Spacer()
                }
                .card()
            }
            .buttonStyle(.plain)
        }
    }
}

/// Exploration-first statistics (spec §42); speed stays secondary.
struct StatsView: View {
    let stats: ExplorationStats?
    let units: Units

    var body: some View {
        if let stats {
            let f = UnitFormatter(units: units)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Spacing.md) {
                RideMetric(title: "New territory", value: f.distance(meters: stats.newTerritoryKm * 1000), compact: true)
                RideMetric(title: "Unique roads", value: f.distance(meters: stats.uniqueRoadsKm * 1000), compact: true)
                RideMetric(title: "Regions visited", value: "\(stats.regionsVisited)", compact: true)
                RideMetric(title: "Quests completed", value: "\(stats.questsCompleted)", compact: true)
                RideMetric(title: "Discoveries", value: "\(stats.discoveriesFound)", compact: true)
                RideMetric(title: "Story quests", value: "\(stats.storyQuestsCompleted)", compact: true)
                RideMetric(title: "Total distance", value: f.distance(meters: stats.totalDistanceMeters), compact: true)
                RideMetric(title: "Total climb", value: f.elevation(meters: stats.totalElevationMeters), compact: true)
            }
            .card()
            if let avg = stats.averageSpeedMps {
                HStack {
                    RideMetric(title: "Average speed", value: f.speed(metersPerSecond: avg), compact: true)
                    Spacer()
                    if let max = stats.maxSpeedMps { RideMetric(title: "Max speed", value: f.speed(metersPerSecond: max), compact: true) }
                }
                .card().opacity(0.8)
            }
        } else {
            ProgressView()
        }
    }
}

struct WorldStatsView: View {
    let stats: ExplorationStats?
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Explored world").font(Theme.Typography.heading)
            if let stats {
                RideMetric(title: "Areas visited", value: "\(stats.cellsVisited)")
                RideMetric(title: "Areas fully explored", value: "\(stats.cellsExplored)")
                RideMetric(title: "Revealed by quests", value: "\(stats.cellsDiscovered ?? 0)")
                Text("Open the World tab to see the fog you have cleared.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            } else { ProgressView() }
        }
        .card()
    }
}

struct AdventureDetailView: View {
    @Environment(AppContainer.self) private var container
    let entry: AdventureEntry
    @State private var geometry: RideGeometry?
    @State private var notes: String = ""
    @State private var shareURL: URL?

    var body: some View {
        let f = UnitFormatter(units: container.session.units)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                MapLibreView(styleURL: Config.mapStyleURL(for: .minimal), center: geometry?.path.first, zoom: 12, cells: [], route: geometry?.path ?? [], markers: [])
                    .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                Text(entry.quest?.title ?? "Free ride").font(Theme.Typography.display)
                Text("+\(entry.xpAwarded) XP").font(Theme.Typography.title).foregroundStyle(Theme.Colors.moss)
                HStack(spacing: Theme.Spacing.lg) {
                    RideMetric(title: "Ridden", value: f.distance(meters: entry.ride.distanceMeters), compact: true)
                    RideMetric(title: "Climbed", value: f.elevation(meters: entry.ride.elevationGainMeters), compact: true)
                    RideMetric(title: "Time", value: f.duration(seconds: Double(entry.ride.durationSeconds)), compact: true)
                    RideMetric(title: "New", value: f.distance(meters: entry.newTerritoryMeters), compact: true)
                }
                if !entry.discoveries.isEmpty {
                    Text("Discoveries").font(Theme.Typography.heading)
                    ForEach(entry.discoveries) { DiscoveryCard(discovery: $0) }
                }
                Text("Notes").font(Theme.Typography.heading)
                TextField("What made this ride memorable?", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...6)
                    .onSubmit { Task { _ = try? await container.api.updateRide(id: entry.ride.id, RidePatch(notes: notes)) } }
                HStack {
                    Button("Save notes") { Task { _ = try? await container.api.updateRide(id: entry.ride.id, RidePatch(notes: notes)) } }.buttonStyle(.bordered)
                    ShareLink(item: container.api.rideExportURL(id: entry.ride.id, format: .gpx)) { Label("Export GPX", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Colors.parchment)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            notes = entry.notes ?? ""
            geometry = try? await container.api.rideGeometry(id: entry.ride.id)
        }
    }
}

struct DiscoveryDetailView: View {
    @Environment(AppContainer.self) private var container
    let discoveryId: UUID
    @State private var discovery: Discovery?
    @State private var note = ""
    @State private var rating = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let discovery {
                    DiscoveryCard(discovery: discovery.summary)
                    if let description = discovery.description { Text(description).font(Theme.Typography.body) }
                    Text("Your note").font(Theme.Typography.heading)
                    TextField("Stop safely before writing.", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...6)
                    HStack {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= rating ? "star.fill" : "star").foregroundStyle(Theme.Colors.rune).onTapGesture { rating = star }
                        }
                    }
                    Button("Save") {
                        Task { _ = try? await container.api.updateUserDiscovery(id: discoveryId, UserDiscoveryIn(note: note, rating: rating == 0 ? nil : rating)) }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.Colors.moss)
                } else { ProgressView() }
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Colors.parchment)
        .task {
            discovery = try? await container.api.discovery(id: discoveryId)
            note = discovery?.userDiscovery?.note ?? ""
            rating = discovery?.userDiscovery?.rating ?? 0
        }
    }
}
