import RoadsAndRunesCore
import SwiftUI

struct QuestsView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: QuestsViewModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        if let error = model.error { Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember) }
                        section("Active", model.active, empty: "No active quest. Accept one below and plan a route.")
                        section("Nearby", model.available, empty: model.isLoading ? "Loading…" : "Nothing nearby yet. Move around the map or generate more.")
                        if !model.recommended.isEmpty { section("Recommended for \(model.characterClass.rawValue.capitalized)s", model.recommended, empty: "") }
                        if container.session.isEnabled("story_quests") { section("Story", model.story, empty: "No story quests unlocked.") }
                        if container.session.isEnabled("party_quests") { section("Party", model.party, empty: "No party quests.") }
                        section("Completed", model.completed, empty: "Your completed adventures will appear here.", compact: true)
                        Button("Generate more quests here") { Task { await model.generateMore() } }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                    .padding(Theme.Spacing.md)
                }
            }
            .background(Theme.Colors.parchment)
            .navigationTitle("Quests")
            .navigationDestination(for: Quest.self) { quest in QuestDetailView(quest: quest) }
            .refreshable { await model?.load() }
        }
        .task {
            if model == nil { model = QuestsViewModel(container: container) }
            await model?.load()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ quests: [Quest], empty: String, compact: Bool = false) -> some View {
        SectionHeader(title: title)
        if quests.isEmpty {
            if !empty.isEmpty { Text(empty).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary) }
        } else {
            ForEach(quests) { quest in
                NavigationLink(value: quest) { QuestCard(quest: quest, compact: compact, units: model?.units ?? .metric) }.buttonStyle(.plain)
            }
        }
    }
}

struct QuestDetailView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: QuestDetailModel?
    @State private var showPlanner = false
    let quest: Quest

    var body: some View {
        Group {
            if let model { content(model) } else { ProgressView() }
        }
        .background(Theme.Colors.parchment)
        .navigationBarTitleDisplayMode(.inline)
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
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack { DifficultyChip(difficulty: quest.difficulty.rawValue); Text(quest.characterClass.rawValue).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary) }
                Text(quest.title).font(Theme.Typography.display)
                Text(quest.narrative.hook ?? quest.description).font(Theme.Typography.body)
                HStack(spacing: Theme.Spacing.md) {
                    StatChip(icon: "point.topleft.down.to.point.bottomright.curvepath", text: UnitFormatter(units: model.units).distance(meters: quest.recommendedDistanceKm * 1000))
                    StatChip(icon: "clock", text: UnitFormatter(units: model.units).duration(seconds: Double(quest.estimatedDurationMinutes * 60)))
                    StatChip(icon: "sparkles", text: "\(quest.baseXP) XP")
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Objectives").font(Theme.Typography.heading)
                    ForEach(quest.sortedObjectives) { objective in
                        ObjectiveRow(objective: objective, distanceMeters: model.distance(to: objective), units: model.units)
                    }
                }
                .card()
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Rewards").font(Theme.Typography.heading)
                    Text("+\(quest.rewards.xp ?? quest.baseXP) XP base · plus exploration and discovery XP, validated after the ride").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                .card()
                if let error = model.error { Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember) }
                actions(model)
            }
            .padding(Theme.Spacing.md)
        }
    }

    @ViewBuilder
    private func actions(_ model: QuestDetailModel) -> some View {
        let quest = model.quest
        HStack(spacing: Theme.Spacing.sm) {
            switch quest.status {
            case .available:
                Button { Task { await model.accept() } } label: { Text("Accept").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                Button { showPlanner = true } label: { Text("Plan route").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Colors.moss)
            case .accepted, .active:
                Button(role: .destructive) { Task { await model.abandon() } } label: { Text("Abandon").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
                Button { showPlanner = true } label: { Text(quest.status == .active ? "Continue" : "Plan route").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Colors.moss)
            default:
                Text(quest.status.rawValue.capitalized).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .disabled(model.busy || container.rideRecorder.isActive)
    }
}
