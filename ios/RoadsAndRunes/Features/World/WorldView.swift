import RoadsAndRunesArt
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
    @State private var onScreen = false
    var onOpenCharacter: () -> Void = {}
    /// A quest's marker was tapped: quests are read on their own tab.
    var onOpenQuests: () -> Void = {}

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
        }
        // The map in the hand needs to know thirty metres from fifty; put away, it
        // goes back to the coarse fix that costs nothing. Neither touches a ride's GPS.
        .onAppear {
            onScreen = true
            container.location.startBrowsing()
        }
        .onDisappear {
            onScreen = false
            container.location.startPassive()
        }
        // A ride stops the location manager when it ends; the map must start it again
        // or the player's position stays where the ride finished.
        .onChange(of: container.rideRecorder.isActive) { _, riding in
            guard !riding else { return }
            if onScreen { container.location.startBrowsing() } else { container.location.startPassive() }
        }
        .onChange(of: container.location.lastFix) { _, fix in
            guard let fix, let model else { return }
            if model.center == nil { model.center = fix.coordinate }
            Task { await model.load(around: fix.coordinate) }
            if !container.rideRecorder.isActive, withAnimation(.snappy, { model.noticeReach() }) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        .onChange(of: container.rideRecorder.localCellStates) { _, _ in model?.rebuildCells() }
        .onChange(of: model?.openedQuestMarker) { _, quest in
            guard quest != nil else { return }
            model?.openedQuestMarker = nil
            onOpenQuests()
        }
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
                inkWash: model.inkWash,
                reach: model.reach,
                markers: model.markers + model.cutMarkers,
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
                        // The frontier chevron (0.7.0, ink fog): which way the nearest unexplored tile lies.
                        if let bearing = model.frontierBearing {
                            Button { model.goToFrontier() } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 18, weight: .heavy))
                                    .foregroundStyle(Theme.Colors.ink)
                                    .rotationEffect(.degrees(bearing))
                                    .frame(width: 48, height: 48)
                                    .background(Theme.Colors.cream, in: Circle())
                                    .overlay(Circle().stroke(Theme.Colors.ink.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [1, 3])))
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel("Nearest unexplored area")
                            .accessibilityIdentifier("world.frontier")
                        }
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
                        .accessibilityLabel("Plan a route from here")
                    }
                }
                .padding(.horizontal, 16)
                if let claimed = model.recentClaim {
                    VStack(spacing: 6) {
                        ClaimToast(object: claimed)
                        if let detail = model.recentClaimDetail {
                            MapPill(text: detail, icon: .sparkles).accessibilityIdentifier("claimSet")
                        }
                        if let quest = model.recentQuestTitle {
                            MapPill(text: "Quest complete: \(quest)", icon: .scroll)
                                .accessibilityIdentifier("claimQuestComplete")
                        }
                    }
                    .padding(.horizontal, 16)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
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
                inReach: model.isWithinReach(object),
                groundRound: model.groundRound?.objectId == object.id ? model.groundRound : nil,
                claiming: model.claiming == object.id,
                claimError: model.claimError,
                onClaim: { Task { await model.claim(object) } },
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
                onClose: { withAnimation(.snappy) { model.closePlace() } },
                // The lamp only on a server that places one fairly (0.6.1+, which sends `combat`):
                // an older one took the coins and on most days placed nothing.
                lampCost: container.session.config?.combat != nil ? WorldViewModel.lampCost : nil,
                lampCheck: model.lampCheck,
                leavingLamp: model.leavingLamp,
                lampError: model.lampError,
                onLamp: { Task { await model.leaveLamp(at: place) } }
            )
            .task(id: place.id) {
                if container.session.config?.combat != nil { await model.checkLamp(at: place) }
            }
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
                    Label("Hidden places", systemImage: container.mapPreferences.showMysteries ? "checkmark" : "questionmark.circle")
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
        case .minimal: return "\(name(for: style)) · just the streets"
        case .cycling: return "\(name(for: style)) · cycleways in green"
        case .adventure: return "\(name(for: style)) · trails and parks"
        case .detailed: return "\(name(for: style)) · everything"
        default: return name(for: style)
        }
    }

    /// The style's short name: "Outdoors" for the trails-and-parks style.
    static func name(for style: MapStyle) -> String {
        style == .adventure ? "Outdoors" : style.rawValue.capitalized
    }
}
