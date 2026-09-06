import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class RoutePlannerViewModel {
    var request = ""
    var distanceKm: Double
    var selectedBike: Bike?
    private(set) var bikes: [Bike] = []
    private(set) var alternatives: [RouteOption] = []
    var selected: RouteOption?
    private(set) var isGenerating = false
    private(set) var isStarting = false
    var error: String?
    let quest: Quest?
    private let container: AppContainer

    init(quest: Quest?, container: AppContainer) {
        self.quest = quest
        self.container = container
        self.distanceKm = quest?.recommendedDistanceKm ?? 25
    }

    var units: Units { container.session.units }

    func loadBikes() async {
        bikes = (try? await container.api.bikes()) ?? []
        selectedBike = bikes.first { $0.isDefault } ?? bikes.first
    }

    func generate() async {
        guard let origin = container.location.lastFix?.coordinate ?? quest?.origin else {
            error = "Waiting for your location"
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        do {
            let response = try await container.api.generateRoutes(RouteGenerateRequest(origin: origin, bikeId: selectedBike?.id, questId: quest?.id, distanceTargetKm: distanceKm, loop: true, request: request.isEmpty ? nil : request))
            alternatives = response.alternatives
            selected = alternatives.first { $0.label == "Adventure" } ?? alternatives.first
            error = nil
            container.analytics.track(.routeGenerated, properties: ["count": String(alternatives.count), "engine": response.engine ?? "unknown"])
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Accepts the quest if needed, downloads the package and starts the ride (spec §96 steps 12–13).
    func startRide() async -> Bool {
        guard let selected else { return false }
        isStarting = true
        defer { isStarting = false }
        do {
            var quest = self.quest
            if let q = quest, q.status == .available {
                quest = try await container.api.acceptQuest(id: q.id)
            }
            let package = try await container.api.routePackage(id: selected.id)
            container.analytics.track(.routeSelected, properties: ["routeId": selected.id.uuidString, "label": selected.label])
            if let quest { container.analytics.track(.questStarted, properties: ["questId": quest.id.uuidString]) }
            await container.rideRecorder.start(package: package, quest: quest ?? package.quest, bikeId: selectedBike?.id)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct RoutePlannerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: RoutePlannerViewModel?
    let quest: Quest?

    var body: some View {
        NavigationStack {
            Group {
                if let model { content(model) } else { ProgressView() }
            }
            .background(Theme.Colors.parchment)
            .navigationTitle("Choose a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task {
            if model == nil { model = RoutePlannerViewModel(quest: quest, container: container) }
            await model?.loadBikes()
            if model?.alternatives.isEmpty == true { await model?.generate() }
        }
    }

    @ViewBuilder
    private func content(_ model: RoutePlannerViewModel) -> some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let quest = model.quest { Text(quest.title).font(Theme.Typography.title) }
                TextField("around 30 km, quiet roads, a pub near the end", text: $model.request, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Distance \(Int(model.distanceKm)) km").font(Theme.Typography.caption)
                    Slider(value: $model.distanceKm, in: 5...150, step: 1)
                }
                if !model.bikes.isEmpty {
                    Picker("Bike", selection: $model.selectedBike) {
                        ForEach(model.bikes) { bike in Text(bike.name).tag(Optional(bike)) }
                    }
                    .pickerStyle(.menu)
                }
                Button { Task { await model.generate() } } label: {
                    Label(model.isGenerating ? "Generating…" : "Generate routes", systemImage: "arrow.triangle.branch").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(model.isGenerating)
                if let error = model.error { Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember) }
                ForEach(model.alternatives) { route in
                    Button { model.selected = route } label: {
                        RouteCard(route: route, selected: model.selected?.id == route.id, units: model.units)
                    }
                    .buttonStyle(.plain)
                }
                if model.selected != nil {
                    Button {
                        Task { if await model.startRide() { dismiss() } }
                    } label: {
                        Text(model.isStarting ? "Downloading route…" : "Download route & start ride").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Colors.moss)
                    .disabled(model.isStarting || container.rideRecorder.isActive)
                }
            }
            .padding(Theme.Spacing.md)
        }
    }
}
