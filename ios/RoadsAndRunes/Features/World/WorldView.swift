import RoadsAndRunesCore
import SwiftUI

/// The World is the home: the map first (design 9a's map with fog of war),
/// used like any maps app — search, tap a place, long-press to drop a pin,
/// then ride there. Quests live on the Quests tab.
struct WorldView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: WorldViewModel?
    @State private var searching = false
    @State private var directionsTo: Place?
    @State private var planningFreeRide = false
    var onOpenCharacter: () -> Void = {}

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
                zoom: 14,
                cells: model.cells,
                markers: model.markers,
                emphasis: styleKey.emphasis,
                onRegionChanged: { center, _ in Task { await model.load(around: center) } },
                onMarkerTap: { marker in withAnimation(.snappy) { model.tapMarker(marker) } },
                camera: model.camera,
                onMapTap: { coordinate, feature in withAnimation(.snappy) { model.tapMap(at: coordinate, feature: feature) } },
                onLongPress: { coordinate in withAnimation(.snappy) { model.dropPin(at: coordinate) } },
                onVisibleRegionChanged: { model.regionChanged($0) }
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                WorldSearchBar(character: container.session.character, onSearch: { searching = true }, onCharacter: onOpenCharacter)
                    .padding(.horizontal, 16)
                PlaceShortcutChips(active: model.activeShortcut) { shortcut in
                    Task { await model.runShortcut(shortcut) }
                }
                HStack {
                    Spacer()
                    MapStyleMenu()
                }
                .padding(.horizontal, 16)
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        IconCircleButton(symbol: "location.fill", size: 48) { model.locateMe() }
                            .accessibilityLabel("Show my location")
                        Button { planningFreeRide = true } label: {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Theme.Colors.cream)
                                .frame(width: 58, height: 58)
                                .background(Theme.Colors.terracotta, in: Circle())
                                .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 6, y: 3)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Plan a ride from here")
                    }
                }
                .padding(.horizontal, 16)
                if model.selectedPlace == nil, model.selectedObject == nil, model.resultsTitle == nil {
                    TodayStrip(
                        character: container.session.character,
                        nearest: model.nearestObject?.object,
                        nearestMeters: model.nearestObject?.meters,
                        activity: container.session.defaultActivity,
                        units: model.units,
                        onNearest: { if let nearest = model.nearestObject?.object { withAnimation(.snappy) { model.open(nearest) } } }
                    )
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomCard(model)
            }
            .padding(.top, 8)
            // The floating tab bar is drawn over the content, not inset from it.
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .fullScreenCover(isPresented: $searching) {
            PlaceSearchScreen(
                search: model.search,
                onPick: { completion in
                    searching = false
                    Task { await model.pick(completion) }
                },
                onSubmit: { text in
                    searching = false
                    Task { await model.submit(text) }
                },
                onShortcut: { shortcut in
                    searching = false
                    Task { await model.runShortcut(shortcut) }
                }
            )
        }
        .sheet(item: $directionsTo) { place in RoutePlannerView(quest: nil, destination: place) }
        .sheet(isPresented: $planningFreeRide) { RoutePlannerView(quest: nil) }
    }

    @ViewBuilder
    private func bottomCard(_ model: WorldViewModel) -> some View {
        if let object = model.selectedObject {
            EncounterCard(
                object: object,
                distanceMeters: model.position.map { GeoMath.distance($0, object.coordinate) },
                units: model.units,
                onPlan: { directionsTo = WorldViewModel.place(for: object) },
                onClose: { withAnimation(.snappy) { model.closeObject() } }
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let place = model.selectedPlace {
            PlaceCard(
                place: place,
                distanceMeters: model.position.map { GeoMath.distance($0, place.coordinate) },
                units: model.units,
                onDirections: { directionsTo = place },
                onClose: { withAnimation(.snappy) { model.closePlace() } }
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let title = model.resultsTitle {
            PlaceResultsCard(
                title: title,
                places: model.results,
                origin: model.position,
                units: model.units,
                isLoading: model.isSearching,
                onSelect: { place in withAnimation(.snappy) { model.select(place) } },
                onClose: { withAnimation(.snappy) { model.clearResults() } }
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
            Section("Map") {
                ForEach([MapStyle.minimal, .cycling, .adventure, .detailed], id: \.self) { style in
                    Button {
                        container.mapPreferences.mapStyle = style
                    } label: {
                        Label(Self.title(for: style), systemImage: container.mapPreferences.mapStyle == style ? "checkmark" : "map")
                    }
                }
            }
            Section("Show") {
                Button {
                    container.mapPreferences.showMysteries.toggle()
                } label: {
                    Label("Undiscovered places (?)", systemImage: container.mapPreferences.showMysteries ? "checkmark" : "questionmark.circle")
                }
                .accessibilityIdentifier("map.showMysteries")
            }
        } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.Colors.ink)
                .frame(width: 42, height: 42)
                .background(Theme.Colors.cream.opacity(0.96), in: Circle())
                .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 2, y: 1)
        }
        .accessibilityLabel("Map style")
    }

    /// What each view is for, since the names alone did not say.
    static func title(for style: MapStyle) -> String {
        switch style {
        case .minimal: return "Minimal · just the streets"
        case .cycling: return "Cycling · cycleways in green"
        case .adventure: return "Adventure · trails and parks"
        case .detailed: return "Detailed · everything"
        default: return style.rawValue.capitalized
        }
    }
}
