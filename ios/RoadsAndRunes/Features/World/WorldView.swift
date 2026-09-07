import RoadsAndRunesCore
import SwiftUI

/// Default tab (spec §4): map, fog, quest markers, discoveries, nearby quests.
struct WorldView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: WorldViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
        }
        .task {
            if model == nil { model = WorldViewModel(container: container) }
            container.location.requestWhenInUse()
            container.location.startPassive()
        }
        .onChange(of: container.location.lastFix) { _, fix in
            guard let fix, let model else { return }
            if model.center == nil { model.center = fix.coordinate }
            Task { await model.load(around: fix.coordinate) }
        }
        .onChange(of: container.rideRecorder.localCellStates) { _, _ in model?.rebuildCells() }
        .onChange(of: container.sync.latestSummary) { _, summary in
            guard summary == nil, let model, let center = model.center else { return }
            Task { await model.load(around: center, force: true) }
        }
    }

    @ViewBuilder
    private func content(_ model: WorldViewModel) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                MapLibreView(
                    styleURL: Config.mapStyleURL(for: styleKey),
                    center: model.center ?? container.location.lastFix?.coordinate ?? SampleData.origin,
                    zoom: 13.5,
                    cells: model.cells,
                    route: [],
                    markers: model.markers,
                    onRegionChanged: { center, _ in
                        Task { await model.load(around: center) }
                    },
                    onMarkerTap: { marker in model.select(marker: marker) }
                )
                .ignoresSafeArea(edges: .top)
                HStack(spacing: Theme.Spacing.sm) {
                    HStack {
                        if let stats = model.stats {
                            Text("\(UnitFormatter(units: model.units).distance(meters: stats.newTerritoryKm * 1000)) new · \(stats.cellsVisited) areas")
                                .font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.Colors.moss)
                        } else {
                            Text("Exploring…").font(Theme.Typography.caption)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
                    .background(.regularMaterial, in: Capsule())
                    Spacer()
                    MapStyleMenu()
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.sm)
            }
            NearbyQuestsPanel(model: model)
                .frame(height: 260)
        }
        .navigationDestination(item: Binding(get: { model.selectedQuest }, set: { model.selectedQuest = $0 })) { quest in
            QuestDetailView(quest: quest)
        }
    }

    private var styleKey: Config.MapStyleKey {
        switch container.mapPreferences.mapStyle {
        case .minimal: return .minimal
        case .cycling: return .cycling
        case .detailed: return .detailed
        default: return .adventure
        }
    }
}

struct MapStyleMenu: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        Menu {
            ForEach([MapStyle.minimal, .cycling, .adventure, .detailed], id: \.self) { style in
                Button {
                    container.mapPreferences.mapStyle = style
                } label: {
                    Label(style.rawValue.capitalized, systemImage: container.mapPreferences.mapStyle == style ? "checkmark" : "map")
                }
            }
        } label: {
            Label(container.mapPreferences.mapStyle.rawValue.capitalized, systemImage: "chevron.down")
                .font(Theme.Typography.caption.weight(.semibold))
                .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
                .background(.regularMaterial, in: Capsule())
        }
    }
}

struct NearbyQuestsPanel: View {
    let model: WorldViewModel

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.black.opacity(0.2)).frame(width: 36, height: 5).padding(.top, Theme.Spacing.sm)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack {
                        Text("Nearby adventures").font(Theme.Typography.title)
                        Spacer()
                        Text("\(model.nearbyQuests.count) quests").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                    }
                    if let error = model.error, model.nearbyQuests.isEmpty {
                        Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember)
                    }
                    if model.nearbyQuests.isEmpty && !model.isLoading {
                        EmptyState(icon: "map", title: "No quests yet", message: "Move the map or wait for your location to load nearby adventures.")
                    }
                    ForEach(model.nearbyQuests) { quest in
                        Button { model.selectedQuest = quest } label: {
                            QuestCard(quest: quest, compact: false, units: model.units)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.Spacing.md)
            }
        }
        .background(Theme.Colors.parchment)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
    }
}
