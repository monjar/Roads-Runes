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
    @State private var showingLegend = false
    var onOpenCharacter: () -> Void = {}
    /// A quest's marker was tapped (its id), or the board was asked for (nil):
    /// quests are read on their own tab.
    var onOpenQuests: (UUID?) -> Void = { _ in }

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
            // Today's pledge, for its row under Next up (0.7.3).
            await container.pledges.refresh()
            // The legend awake (0.8.0), for its mark and Next up.
            await container.legends.refresh()
            // The districts passed through (0.9.0), for their names when zoomed out.
            await container.districts.refresh()
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
            // Which district this is, for Next up (0.9.0); the ride asks for its own.
            if !container.rideRecorder.isActive { Task { await container.districts.noticePosition(fix.coordinate) } }
            if !container.rideRecorder.isActive, withAnimation(.snappy, { model.noticeReach() }) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
        .onChange(of: container.rideRecorder.localCellStates) { _, _ in model?.rebuildCells() }
        .onChange(of: model?.openedQuestMarker) { _, quest in
            guard let quest else { return }
            model?.openedQuestMarker = nil
            onOpenQuests(quest)
        }
        .onChange(of: container.sync.latestSummary) { _, summary in
            if let summary {
                Task { await container.pledges.journeyEnded(summary) }
                Task { await container.legends.journeyEnded(summary) }
                Task { await container.districts.journeyEnded(summary) }
            }
            guard summary == nil, let model, let center = model.center else { return }
            Task { await model.load(around: center, force: true) }
        }
    }

    @ViewBuilder
    private func content(_ model: WorldViewModel) -> some View {
        ZStack(alignment: .top) {
            MapLibreView(
                styleURL: worldStyleURL,
                center: model.center ?? container.location.lastFix?.coordinate ?? SampleData.origin,
                zoom: 14,
                cells: model.cells,
                inkWash: model.inkWash,
                reach: model.reach,
                lairTiles: model.lairTiles,
                markers: model.markers + model.cutMarkers,
                // District names, quiet and only zoomed out; the rider in the frame worn (0.9.0).
                labels: container.districts.labels,
                riderFrame: container.session.inventory?.look?.markerFrame,
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
                HStack(spacing: 10) {
                    Spacer()
                    // What every mark on the map is (MapLegend).
                    Button { showingLegend = true } label: {
                        Image(systemName: "questionmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.Colors.ink)
                            .frame(width: 42, height: 42)
                            .background(Theme.Colors.cream.opacity(0.96), in: Circle())
                            .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 2, y: 1)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("What's on the map")
                    .accessibilityIdentifier("world.legend")
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
                        // The main thing to do, said in words: an icon alone did not say it.
                        Button { planningFreeRide = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                    .font(.system(size: 18, weight: .bold))
                                Text("Plan a \(container.session.defaultActivity.noun)")
                                    .font(Theme.Typography.text(15, .bold))
                            }
                            .foregroundStyle(Theme.Colors.cream)
                            .padding(.horizontal, 18)
                            .frame(height: 52)
                            .background(Theme.Colors.terracotta, in: Capsule())
                            .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 6, y: 3)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("world.plan")
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
                if let note = model.cutNote {
                    MapPill(text: note, icon: .runeStone)
                        .accessibilityIdentifier("world.cutNote")
                        .transition(.opacity)
                }
                if model.selectedPlace == nil, model.selectedObject == nil, model.resultsTitle == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        // The streak; what is near is the Next up card's to say.
                        TodayStrip(
                            character: container.session.character,
                            nearest: nil,
                            activity: container.session.defaultActivity,
                            units: model.units,
                            onNearest: {}
                        )
                        NextUpCard(next: model.nextUp, units: model.units, activity: container.session.defaultActivity,
                                   pledge: container.pledges.isOn ? container.pledges.today : nil,
                                   district: container.districts.milestoneLine) {
                            act(on: model.nextUp, model)
                        }
                    }
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
        // A legend's page (0.8.0), from its mark on the map.
        .sheet(item: Binding(get: { model.openedLegend }, set: { model.openedLegend = $0 })) { legend in
            LegendPage(legendId: legend.id)
        }
        .sheet(isPresented: $showingLegend) { MapLegend() }
        .sheet(isPresented: $planningFreeRide) { RoutePlannerView(quest: nil) }
    }

    /// The Next up card's one button.
    private func act(on next: NextUp, _ model: WorldViewModel) {
        switch next {
        case .firstRide: planningFreeRide = true
        case .inReach(let object): withAnimation(.snappy) { model.open(object) }
        case .skillPoints: onOpenCharacter()
        case .creature(let object, _), .treasure(let object, _): directionsTo = WorldViewModel.place(for: object)
        case .legend(let legend, _): directionsTo = WorldViewModel.place(for: legend)
        case .quests: onOpenQuests(nil)
        }
    }

    @ViewBuilder
    private func bottomCard(_ model: WorldViewModel) -> some View {
        if let lair = model.selectedObject, lair.isLair {
            // A lair (0.8.0): its tiles to visit, by when, and its great chest.
            LairCard(
                lair: lair,
                distanceMeters: model.position.map { GeoMath.distance($0, lair.coordinate) },
                units: model.units,
                onPlan: { directionsTo = WorldViewModel.place(for: lair) },
                onClose: { withAnimation(.snappy) { model.closeObject() } }
            )
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let object = model.selectedObject {
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

    /// The Outdoors style becomes the parchment map on the World tab only, behind
    /// `parchment_map` (0.7.3); every other style and tab is as it was.
    private var worldStyleURL: URL {
        if styleKey == .adventure, container.session.isEnabled("parchment_map"), let parchment = Config.parchmentStyleURL {
            return parchment
        }
        return Config.mapStyleURL(for: styleKey)
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
