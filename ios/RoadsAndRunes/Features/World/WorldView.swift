import RoadsAndRunesCore
import SwiftUI

/// The World is the home (design 9a): a full-screen ink map that only exists
/// where you have ridden. Fog is the hero; the character chip sits top-left,
/// one Nearby sheet rises from the bottom.
struct WorldView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: WorldViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ZStack {
                        Theme.Colors.cream.ignoresSafeArea()
                        ProgressView().tint(Theme.Colors.terracotta)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
            .ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    if let character = container.session.character {
                        CharacterChip(character: character)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        MapPill(text: exploredText(model))
                        MapStyleMenu()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer(minLength: 0)
                NearbyQuestsPanel(model: model, position: container.location.lastFix?.coordinate)
            }
        }
        .background(Theme.Colors.cream)
        .navigationDestination(item: Binding(get: { model.selectedQuest }, set: { model.selectedQuest = $0 })) { quest in
            QuestDetailView(quest: quest)
        }
    }

    private func exploredText(_ model: WorldViewModel) -> String {
        guard let stats = model.stats else { return "Exploring…" }
        let area = Double(stats.cellsVisited) * 0.1053
        let areaText = area >= 10 ? "\(Int(area.rounded())) km²" : String(format: "%.1f km²", area)
        return "\(areaText) explored"
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
            Image(systemName: "map")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.Colors.ink)
                .frame(width: 40, height: 40)
                .background(Theme.Colors.cream.opacity(0.94), in: Circle())
                .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 2, y: 1)
        }
        .accessibilityLabel("Map style")
    }
}

/// "Nearby · 3 quests · 5 mysteries": quest rows with class tiles.
struct NearbyQuestsPanel: View {
    let model: WorldViewModel
    var position: Coordinate?

    var body: some View {
        VStack(spacing: 12) {
            SheetHandle()
            HStack(alignment: .firstTextBaseline) {
                Text("Nearby").font(Theme.Typography.voice(22, relativeTo: .title2)).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Text(summaryLine).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if let error = model.error, model.nearbyQuests.isEmpty {
                        ErrorLine(text: error)
                    }
                    if model.nearbyQuests.isEmpty && !model.isLoading {
                        EmptyState(icon: "sparkle", title: "No quests here yet", message: "Move the map or wait for your location to find adventures nearby.")
                    }
                    ForEach(model.nearbyQuests) { quest in
                        Button { model.selectedQuest = quest } label: {
                            QuestCard(quest: quest, units: model.units, distanceMeters: position.map { GeoMath.distance($0, quest.origin) })
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, Theme.Layout.tabBarClearance)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(height: 340)
        .sheetSurface()
        .ignoresSafeArea(edges: .bottom)
    }

    private var summaryLine: String {
        let quests = model.nearbyQuests.count
        let mysteries = model.snapshot?.discoveries.filter { !$0.discoveredByUser }.count ?? 0
        return "\(quests) quest\(quests == 1 ? "" : "s") · \(mysteries) myster\(mysteries == 1 ? "y" : "ies")"
    }
}
