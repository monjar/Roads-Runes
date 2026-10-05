import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Quests tab (design 9b, quest list parts): the current quest as the big ink
/// card, then nearby adventures as rows.
struct QuestsView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: QuestsViewModel?
    @State private var plannerQuest: Quest?
    @State private var planningCustom = false
    @State private var bountyDestination: Place?
    /// Navigation state lives in the view so setting it always pushes the detail.
    @State private var selectedQuest: Quest?
    @State private var showingStory = false
    @State private var showingRunes = false
    /// A quest to open, handed over from a marker tapped on the World map.
    var openQuest: Binding<UUID?> = .constant(nil)

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Quests").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                        if let error = model.error { ErrorLine(text: error) }
                        if let current = model.active.first {
                            CurrentQuestCard(quest: current, units: model.units) {
                                plannerQuest = current
                            } onDetails: {
                                selectedQuest = current
                            }
                            .disabled(container.rideRecorder.isActive)
                        }
                        if model.active.count > 1 {
                            section("Also accepted", Array(model.active.dropFirst()), empty: "", compact: true)
                        }
                        Button { planningCustom = true } label: { CustomAdventureCard() }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("customAdventure")
                            .disabled(container.rideRecorder.isActive)
                        // Pick a time, the board picks the way (0.7.3): planned by the quick start.
                        SealedQuestCard { minutes in
                            QuickStartCoordinator.shared.handle(.sealed(minutes: minutes), autoStart: false)
                        }
                        .disabled(container.rideRecorder.isActive)
                        // A treasure map's clue (0.8.0): kept here, never a marker on the map.
                        ForEach(container.legends.clues) { clue in TreasureClueCard(clue: clue) }
                        if let notice = model.weekNotice {
                            WeekNoticeCard(notice: notice)
                        }
                        if let bounty = model.bounty {
                            BountyCard(
                                bounty: bounty,
                                distanceMeters: container.location.lastFix.map { GeoMath.distance($0.coordinate, bounty.coordinate) },
                                units: model.units,
                                onPlan: { bountyDestination = WorldViewModel.place(for: bounty) }
                            )
                            .disabled(container.rideRecorder.isActive)
                        }
                        // The story and rune rides near the top, where they can be found.
                        if container.session.isEnabled("story_quests") {
                            section("Story", model.story, empty: "No story quest on the board yet.")
                            shortcut("Story progress", icon: .openBook, id: "quests.story") { showingStory = true }
                        }
                        if container.session.character?.sheet?.inscribed != nil {
                            shortcut("Rune rides · ride a rune's shape", icon: .runeStone, id: "quests.runeRides") { showingRunes = true }
                        }
                        if model.isLoading, model.all.isEmpty {
                            // Loading is not "nothing here": say it is looking.
                            HStack(spacing: 10) {
                                ProgressView().tint(Theme.Colors.terracotta)
                                Text("Finding quests near you…").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .accessibilityIdentifier("quests.loading")
                        }
                        section("Quests nearby", model.available, empty: model.isLoading ? "Finding quests near you…" : "No quests nearby yet. Tap Find more quests below.")
                        if !model.recommended.isEmpty {
                            section("For \(ClassStyle.name(model.characterClass))s", model.recommended, empty: "")
                        }
                        if !model.forAnyone.isEmpty {
                            section("For anyone", model.forAnyone, empty: "")
                        }
                        if container.session.isEnabled("party_quests") { section("Party", model.party, empty: "No party quests yet.") }
                        section("Completed", model.completed, empty: "Finished quests appear here.", compact: true)
                        Button("Find more quests") { Task { await model.generateMore() } }
                            .buttonStyle(.secondaryWide)
                            .accessibilityIdentifier("quests.findMore")
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, Theme.Layout.tabBarClearance)
                }
            }
            .background(Theme.Colors.cream)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedQuest) { quest in QuestDetailView(quest: quest) }
            .navigationDestination(isPresented: $showingRunes) { RunesScreen() }
            .navigationDestination(isPresented: $showingStory) {
                StoryArcsView(onOpenQuest: { questId in
                    // Back to the board, on the step they tapped.
                    guard let quest = model?.all.first(where: { $0.id == questId }) else { return }
                    showingStory = false
                    selectedQuest = quest
                })
            }
            .refreshable {
                await model?.load()
                await container.legends.refreshClues()
            }
            .sheet(item: $plannerQuest) { quest in RoutePlannerView(quest: quest) }
            .sheet(isPresented: $planningCustom) { RoutePlannerView(quest: nil) }
            .sheet(item: $bountyDestination) { place in RoutePlannerView(quest: nil, destination: place) }
            // Back from a quest (accepted, abandoned) or from a ride, the list and the current quest have changed.
            .onChange(of: selectedQuest) { _, quest in
                if quest == nil { Task { await model?.load() } }
            }
            .onChange(of: container.rideRecorder.isActive) { _, active in
                if !active { Task { await model?.load() } }
            }
            .onChange(of: container.sync.latestSummary) { _, summary in
                if summary != nil { Task { await container.legends.refreshClues() } }
            }
            .onChange(of: openQuest.wrappedValue, initial: true) { _, id in
                guard let id else { return }
                Task { await open(questId: id) }
            }
        }
        .task {
            if model == nil { model = QuestsViewModel(container: container) }
            await model?.load()
        }
        .task { await container.legends.refreshClues() }
    }

    /// The quest a World marker pointed at, once the board has it.
    private func open(questId: UUID) async {
        if model == nil { model = QuestsViewModel(container: container) }
        if model?.all.contains(where: { $0.id == questId }) != true { await model?.load() }
        openQuest.wrappedValue = nil
        if let quest = model?.all.first(where: { $0.id == questId }) { selectedQuest = quest }
    }

    /// A row that leads somewhere: an icon, a label, a chevron.
    private func shortcut(_ title: String, icon: GameIcon, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconShape(icon).foregroundStyle(Theme.Colors.terracottaDeep).frame(width: 20, height: 20)
                Text(title).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.muted)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func section(_ title: String, _ quests: [Quest], empty: String, compact: Bool = false) -> some View {
        SectionHeader(title: title, subtitle: quests.isEmpty ? nil : "\(quests.count)")
        if quests.isEmpty {
            if !empty.isEmpty { Text(empty).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted) }
        } else {
            ForEach(quests) { quest in
                Button { selectedQuest = quest } label: {
                    QuestCard(quest: quest, compact: compact, units: model?.units ?? .metric, distanceMeters: distance(to: quest))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("questRow")
            }
        }
    }

    /// How far the quest's nearest place is. A quest starts where the player is, so
    /// "how far away is it" is how far to where it goes; one that goes nowhere in
    /// particular (a distance, new roads) is not away at all.
    private func distance(to quest: Quest) -> Double? {
        guard let position = container.location.lastFix?.coordinate else { return nil }
        return quest.objectives
            .filter { $0.objectiveType != .returnToStart }
            .compactMap(\.coordinate)
            .map { GeoMath.distance(position, $0) }
            .min()
    }
}

/// Quest detail (design 10a): map-led. Numbered diamonds on the ink map, the
/// story in one paragraph, objectives as a checklist, journey facts and the
/// cycling-suitability line before Begin.
struct QuestDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: QuestDetailModel?
    @State private var showPlanner = false
    let quest: Quest

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Colors.cream.ignoresSafeArea()
            if let model { content(model) } else { ProgressView().tint(Theme.Colors.terracotta) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        // A ride started from here changes the quest (accepted → completed); show the new state.
        .onChange(of: container.rideRecorder.isActive) { _, active in
            if !active { Task { await model?.refresh() } }
        }
        .task {
            if model == nil { model = QuestDetailModel(quest: quest, container: container) }
            await model?.refresh()
            await model?.loadRoute()
        }
        .sheet(isPresented: $showPlanner) {
            if let model { RoutePlannerView(quest: model.quest) }
        }
    }

    @ViewBuilder
    private func content(_ model: QuestDetailModel) -> some View {
        let quest = model.quest
        let formatter = UnitFormatter(units: model.units)
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ZStack(alignment: .top) {
                        MapLibreView(
                            styleURL: Config.mapStyleURL(for: .adventure),
                            center: model.position ?? quest.origin,
                            zoom: 12.5,
                            cells: [],
                            route: model.route?.path ?? [],
                            guide: model.guide,
                            markers: markers(for: quest, route: model.route, focused: model.focusedStop),
                            emphasis: .adventure,
                            onMarkerTap: { marker in
                                guard let poi = model.route?.pois.first(where: { "stop-\($0.id.uuidString)" == marker.id }) else { return }
                                withAnimation(.snappy) { model.focus(poi) }
                            },
                            camera: model.routeCamera
                        )
                        .frame(height: 360)
                        .overlay(alignment: .bottom) {
                            if let stop = model.focusedStop {
                                StopCallout(poi: stop, units: model.units) { withAnimation(.snappy) { model.focus(nil) } }
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 44)
                                    .transition(.opacity)
                            } else {
                                routeStatus(model)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 44)
                            }
                        }
                        HStack {
                            IconCircleButton(symbol: "chevron.left") { dismiss() }.accessibilityLabel("Back").accessibilityIdentifier("quest.back")
                            Spacer()
                            HStack(spacing: 8) {
                                ClassEmblem(characterClass: quest.characterClass, size: 22)
                                Eyebrow(text: "\(ClassStyle.name(quest.characterClass)) quest", color: Theme.Colors.cream)
                            }
                            .foregroundStyle(Theme.Colors.cream)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(ClassStyle.color(quest.characterClass), in: Capsule())
                        }
                        .padding(.horizontal, 16)
                        // The scroll view runs under the status bar; keep the controls below it.
                        .padding(.top, geometry.safeAreaInsets.top + 8)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(quest.title).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                        Text(quest.narrative.hook ?? quest.description).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft).lineSpacing(3)
                        if let poster = quest.narrative.poster { PosterLine(poster: poster) }
                        VStack(spacing: 8) {
                            let objectives = quest.sortedObjectives
                            ForEach(Array(objectives.enumerated()), id: \.element.id) { offset, objective in
                                ObjectiveRow(
                                    objective: SealedQuestCopy.shown(objective, in: quest),
                                    distanceMeters: model.distance(to: objective),
                                    units: model.units,
                                    index: objective.required ? requiredIndex(objectives, offset) : nil,
                                    accent: ClassStyle.color(quest.characterClass)
                                )
                            }
                        }
                        HStack(spacing: 8) {
                            FactTile(value: formatter.distance(meters: model.route?.distanceMeters ?? quest.recommendedDistanceKm * 1000), label: "Distance")
                            FactTile(value: formatter.duration(seconds: model.route.map { Double($0.estimatedDurationSeconds) } ?? Double(quest.estimatedDurationMinutes * 60)), label: "At your pace")
                            FactTile(value: "\(quest.rewards.xp ?? quest.baseXP)", label: rewardLabel(quest), valueColor: Theme.Colors.sageDeep)
                        }
                        ForEach(Array(quest.rewards.rewardItems.enumerated()), id: \.offset) { _, item in
                            QuestItemRewardLine(item: item)
                        }
                        HStack(spacing: 8) {
                            SuitabilityChip(difficulty: quest.difficulty)
                            Text(suitabilityLine(quest)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(2)
                        }
                        if let completion = quest.narrative.completion, quest.status == .completed {
                            Text(completion).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft).italic()
                        }
                        // A promise to go out for it (0.7.3), while it is on the board.
                        if quest.status == .available || quest.status == .accepted {
                            PledgeButton(kind: .quest, targetId: quest.id, targetName: quest.title, mark: .quest)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 130)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sheetSurface()
                    .offset(y: -28)
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        actions(model)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    /// What the map is waiting for, or why it has no route: never a bare map and silence.
    @ViewBuilder
    private func routeStatus(_ model: QuestDetailModel) -> some View {
        switch model.routeState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().tint(Theme.Colors.ink).controlSize(.small)
                Text("Drawing the route from where you are…").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.Colors.cream.opacity(0.94), in: Capsule())
            .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 2, y: 1)
            .accessibilityIdentifier("quest.route.loading")
        case .failed:
            HStack(spacing: 10) {
                Text("Couldn't draw the route").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                Button("Try again") { Task { await model.retryRoute() } }
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Colors.terracottaDeep)
                    .accessibilityIdentifier("quest.route.retry")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Theme.Colors.cream.opacity(0.94), in: Capsule())
            .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 2, y: 1)
        case .idle, .loaded:
            EmptyView()
        }
    }

    private func requiredIndex(_ objectives: [Objective], _ offset: Int) -> Int {
        objectives.prefix(offset + 1).filter { $0.required }.count
    }

    private func rewardLabel(_ quest: Quest) -> String {
        let items = quest.rewards.items?.count ?? 0
        let titles = quest.rewards.titles?.count ?? 0
        if items + titles == 0 { return "XP" }
        return "XP + \(items + titles) reward\(items + titles == 1 ? "" : "s")"
    }

    private func suitabilityLine(_ quest: Quest) -> String {
        let required = quest.requiredObjectives.count
        let optional = quest.objectives.count - required
        var parts = ["\(required) objective\(required == 1 ? "" : "s")"]
        if optional > 0 { parts.append("\(optional) optional") }
        if let expires = quest.expiresAt { parts.append("until \(expires.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: " · ")
    }

    private func markers(for quest: Quest, route: RouteOption?, focused: RoutePOI?) -> [MapMarker] {
        var out: [MapMarker] = quest.sortedObjectives.compactMap { objective in
            guard let coordinate = objective.coordinate else { return nil }
            return MapMarker(id: objective.id.uuidString, coordinate: coordinate, kind: objective.status == .completed ? .objectiveDone : .objective, title: objective.title)
        }
        // What the route passes on the way, so the rider can see where the coffee is.
        // Not for a sealed quest: a stop on its way could name the goal (0.7.3).
        let stops: [RoutePOI] = SealedQuest.isSealed(quest) ? [] : Array(route?.pois.prefix(10) ?? [])
        for poi in stops {
            out.append(MapMarker(
                id: "stop-\(poi.id.uuidString)",
                coordinate: poi.coordinate,
                kind: poi.id == focused?.id ? .stopActive : .stop,
                title: poi.name,
                mark: DiscoveryIcon.mark(for: poi.category)
            ))
        }
        return out
    }

    @ViewBuilder
    private func actions(_ model: QuestDetailModel) -> some View {
        let quest = model.quest
        VStack(alignment: .leading, spacing: 8) {
            // A failed Accept or Abandon says so beside its button, not below the fold.
            if let error = model.error { ErrorLine(text: error) }
            HStack(spacing: 10) {
                switch quest.status {
                case .available:
                    Button { Task { await model.accept() } } label: { busyLabel("Accept quest", busy: model.busy) }
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("quest.accept")
                    Button("Start quest") { showPlanner = true }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("quest.begin")
                case .accepted:
                    Button { Task { await model.abandon() } } label: { busyLabel("Abandon quest", busy: model.busy) }
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("quest.abandon")
                    Button("Plan route") { showPlanner = true }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("quest.plan")
                case .active:
                    Button { Task { await model.abandon() } } label: { busyLabel("Abandon quest", busy: model.busy) }
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("quest.abandon")
                    Button("Continue quest") { showPlanner = true }
                        .buttonStyle(.primary)
                        .accessibilityIdentifier("quest.continue")
                default:
                    Text(quest.status.rawValue.capitalized)
                        .font(Theme.Typography.text(14, .semibold))
                        .foregroundStyle(Theme.Colors.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Layout.primaryButtonHeight)
                        .background(Theme.Colors.surface, in: Capsule())
                }
            }
            .disabled(model.busy || container.rideRecorder.isActive)
        }
    }

    /// Keeps the button's width while its request runs.
    private func busyLabel(_ title: String, busy: Bool) -> some View {
        ZStack {
            Text(title).opacity(busy ? 0 : 1)
            if busy { ProgressView().tint(Theme.Colors.ink) }
        }
    }
}
