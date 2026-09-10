import RoadsAndRunesCore
import SwiftUI

/// Quests tab (design 9b, quest list parts): the current quest as the big ink
/// card, then nearby adventures as rows.
struct QuestsView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: QuestsViewModel?
    @State private var plannerQuest: Quest?

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
                                model.selectedQuest = current
                            }
                            .disabled(container.rideRecorder.isActive)
                        }
                        if model.active.count > 1 {
                            section("Also accepted", Array(model.active.dropFirst()), empty: "", compact: true)
                        }
                        section("Nearby adventures", model.available, empty: model.isLoading ? "Looking around…" : "Nothing nearby yet. Move around the map or generate more.")
                        if !model.recommended.isEmpty {
                            section("For \(ClassStyle.name(model.characterClass))s", model.recommended, empty: "")
                        }
                        if container.session.isEnabled("story_quests") { section("Story", model.story, empty: "No story quests unlocked.") }
                        if container.session.isEnabled("party_quests") { section("Party", model.party, empty: "No party quests.") }
                        section("Completed", model.completed, empty: "Your completed adventures will appear here.", compact: true)
                        Button("Generate more quests here") { Task { await model.generateMore() } }
                            .buttonStyle(.secondaryWide)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .background(Theme.Colors.cream)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Quest.self) { quest in QuestDetailView(quest: quest) }
            .navigationDestination(item: Binding(get: { model?.selectedQuest }, set: { model?.selectedQuest = $0 })) { quest in
                QuestDetailView(quest: quest)
            }
            .refreshable { await model?.load() }
            .sheet(item: $plannerQuest) { quest in RoutePlannerView(quest: quest) }
        }
        .task {
            if model == nil { model = QuestsViewModel(container: container) }
            await model?.load()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ quests: [Quest], empty: String, compact: Bool = false) -> some View {
        SectionHeader(title: title, subtitle: quests.isEmpty ? nil : "\(quests.count)")
        if quests.isEmpty {
            if !empty.isEmpty { Text(empty).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted) }
        } else {
            ForEach(quests) { quest in
                NavigationLink(value: quest) {
                    QuestCard(quest: quest, compact: compact, units: model?.units ?? .metric, distanceMeters: distance(to: quest))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func distance(to quest: Quest) -> Double? {
        guard let position = container.location.lastFix?.coordinate else { return nil }
        return GeoMath.distance(position, quest.origin)
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
        .task {
            if model == nil { model = QuestDetailModel(quest: quest, container: container) }
            await model?.refresh()
        }
        .sheet(isPresented: $showPlanner) {
            if let model { RoutePlannerView(quest: model.quest) }
        }
    }

    @ViewBuilder
    private func content(_ model: QuestDetailModel) -> some View {
        let quest = model.quest
        let formatter = UnitFormatter(units: model.units)
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    MapLibreView(
                        styleURL: Config.mapStyleURL(for: .adventure),
                        center: quest.origin,
                        zoom: 12.5,
                        cells: [],
                        route: [],
                        markers: markers(for: quest)
                    )
                    .frame(height: 360)
                    HStack {
                        IconCircleButton(symbol: "chevron.left") { dismiss() }
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: ClassStyle.symbol(quest.characterClass)).font(.system(size: 13, weight: .bold))
                            Eyebrow(text: "\(ClassStyle.name(quest.characterClass)) quest", color: Theme.Colors.cream)
                        }
                        .foregroundStyle(Theme.Colors.cream)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background(ClassStyle.color(quest.characterClass), in: Capsule())
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(quest.title).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                    Text(quest.narrative.hook ?? quest.description).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft).lineSpacing(3)
                    VStack(spacing: 8) {
                        let objectives = quest.sortedObjectives
                        ForEach(Array(objectives.enumerated()), id: \.element.id) { offset, objective in
                            ObjectiveRow(
                                objective: objective,
                                distanceMeters: model.distance(to: objective),
                                units: model.units,
                                index: objective.required ? requiredIndex(objectives, offset) : nil,
                                accent: ClassStyle.color(quest.characterClass)
                            )
                        }
                    }
                    HStack(spacing: 8) {
                        FactTile(value: formatter.distance(meters: quest.recommendedDistanceKm * 1000), label: "Journey")
                        FactTile(value: formatter.duration(seconds: Double(quest.estimatedDurationMinutes * 60)), label: "At your pace")
                        FactTile(value: "\(quest.rewards.xp ?? quest.baseXP)", label: rewardLabel(quest), valueColor: Theme.Colors.sageDeep)
                    }
                    HStack(spacing: 8) {
                        SuitabilityChip(difficulty: quest.difficulty)
                        Text(suitabilityLine(quest)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(2)
                    }
                    if let completion = quest.narrative.completion, quest.status == .completed {
                        Text(completion).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft).italic()
                    }
                    if let error = model.error { ErrorLine(text: error) }
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
        actions(model)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
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

    private func markers(for quest: Quest) -> [MapMarker] {
        quest.sortedObjectives.compactMap { objective in
            guard let coordinate = objective.coordinate else { return nil }
            return MapMarker(id: objective.id.uuidString, coordinate: coordinate, kind: objective.status == .completed ? .objectiveDone : .objective, title: objective.title)
        }
    }

    @ViewBuilder
    private func actions(_ model: QuestDetailModel) -> some View {
        let quest = model.quest
        HStack(spacing: 10) {
            switch quest.status {
            case .available:
                Button("Accept") { Task { await model.accept() } }.buttonStyle(.secondary)
                Button("Begin quest") { showPlanner = true }.buttonStyle(.primary)
            case .accepted:
                Button("Abandon") { Task { await model.abandon() } }.buttonStyle(.secondary)
                Button("Plan the ride") { showPlanner = true }.buttonStyle(.primary)
            case .active:
                Button("Abandon") { Task { await model.abandon() } }.buttonStyle(.secondary)
                Button("Continue") { showPlanner = true }.buttonStyle(.primary)
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
