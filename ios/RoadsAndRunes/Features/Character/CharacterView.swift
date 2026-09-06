import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class CharacterViewModel {
    private(set) var bikes: [Bike] = []
    private(set) var riderProfile: RiderProfile?
    var error: String?
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    var character: Character? { container.session.character }

    func load() async {
        await container.session.refreshCharacter()
        bikes = (try? await container.api.bikes()) ?? []
        riderProfile = try? await container.api.riderProfile()
    }

    func unlock(_ ability: AbilityState) async {
        do {
            let updated = try await container.api.unlockAbility(id: ability.ability.id)
            container.session.updateCharacter(updated)
            container.analytics.track(.abilityUnlocked, properties: ["ability": ability.ability.id])
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(bike: BikeIn, id: UUID?) async {
        do {
            if let id { _ = try await container.api.updateBike(id: id, bike) } else { _ = try await container.api.createBike(bike) }
            bikes = (try? await container.api.bikes()) ?? bikes
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(bike: Bike) async {
        try? await container.api.deleteBike(id: bike.id)
        bikes.removeAll { $0.id == bike.id }
    }

    func save(profile: RiderProfile) async {
        riderProfile = try? await container.api.updateRiderProfile(profile)
    }
}

struct CharacterView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: CharacterViewModel?
    @State private var editingBike: Bike?
    @State private var addingBike = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        if let character = model.character { CharacterHeader(character: character) }
                        if let error = model.error { Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember) }
                        SectionHeader(title: "Abilities", subtitle: "Abilities shape quests and what the map reveals. They never change route safety.")
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Spacing.sm) {
                            ForEach(model.character?.abilities ?? []) { state in
                                AbilityCard(state: state) { Task { await model.unlock(state) } }
                            }
                        }
                        SectionHeader(title: "Bikes")
                        ForEach(model.bikes) { bike in
                            Button { editingBike = bike } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(bike.name).font(Theme.Typography.heading)
                                        Text("\(bike.bikeType.rawValue.capitalized)\(bike.isDefault ? " · default" : "")").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.Colors.textSecondary)
                                }
                                .card()
                            }
                            .buttonStyle(.plain)
                        }
                        Button { addingBike = true } label: { Label("Add bike", systemImage: "plus") }.buttonStyle(.bordered)
                        if let profile = model.riderProfile {
                            NavigationLink { RiderProfileView(profile: profile) { updated in Task { await model.save(profile: updated) } } } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("Rider profile").font(Theme.Typography.heading)
                                        Text("Comfortable \(Int(profile.comfortableDistanceKm)) km · \(Int(profile.comfortableElevationGain)) m climb · gravel \(Int(profile.gravelComfort * 100))%").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Theme.Colors.textSecondary)
                                }
                                .card()
                            }
                            .buttonStyle(.plain)
                        }
                        SectionHeader(title: "More")
                        NavigationLink("Friends") { FriendsView() }
                        NavigationLink("Integrations") { IntegrationsView() }
                        NavigationLink("Settings") { SettingsView() }
                    }
                    .padding(Theme.Spacing.md)
                }
            }
            .background(Theme.Colors.parchment)
            .navigationTitle("Character")
            .refreshable { await model?.load() }
            .sheet(item: $editingBike) { bike in BikeEditorView(bike: bike) { input in Task { await model?.save(bike: input, id: bike.id) } } onDelete: { Task { await model?.delete(bike: bike) } } }
            .sheet(isPresented: $addingBike) { BikeEditorView(bike: nil) { input in Task { await model?.save(bike: input, id: nil) } } onDelete: {} }
        }
        .task {
            if model == nil { model = CharacterViewModel(container: container) }
            await model?.load()
        }
    }
}

struct BikeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let bike: Bike?
    let onSave: (BikeIn) -> Void
    let onDelete: () -> Void
    @State private var name = ""
    @State private var type: BikeType = .gravel
    @State private var allowGravel = true
    @State private var allowTrails = false
    @State private var technical = 1.0
    @State private var isDefault = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach([BikeType.road, .gravel, .mountain, .hybrid, .folding, .other], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Gravel OK", isOn: $allowGravel)
                Toggle("Trails OK", isOn: $allowTrails)
                VStack(alignment: .leading) {
                    Text("Max technical surface \(Int(technical))")
                    Slider(value: $technical, in: 0...3, step: 1)
                }
                Toggle("Default bike", isOn: $isDefault)
                if bike != nil {
                    Button("Delete bike", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle(bike == nil ? "New bike" : "Edit bike")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(BikeIn(name: name, bikeType: type, allowGravel: allowGravel, allowTrails: allowTrails, maxTechnicalSurface: Int(technical), isDefault: isDefault))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let bike {
                    name = bike.name; type = bike.bikeType; allowGravel = bike.allowGravel; allowTrails = bike.allowTrails
                    technical = Double(bike.maxTechnicalSurface); isDefault = bike.isDefault
                }
            }
        }
    }
}

/// The cycling difficulty profile (spec §30). Deliberately separate from the RPG character.
struct RiderProfileView: View {
    @State var profile: RiderProfile
    let onSave: (RiderProfile) -> Void

    var body: some View {
        Form {
            Section("Comfort") {
                slider("Comfortable distance", value: $profile.comfortableDistanceKm, range: 5...200, unit: "km")
                slider("Comfortable climbing", value: $profile.comfortableElevationGain, range: 0...3000, unit: "m")
                slider("Max preferred gradient", value: $profile.maxPreferredGradient, range: 2...25, unit: "%")
            }
            Section("Preferences") {
                fraction("Traffic tolerance", value: $profile.trafficTolerance)
                fraction("Gravel comfort", value: $profile.gravelComfort)
                fraction("Technical trail comfort", value: $profile.technicalTrailComfort)
                fraction("Cycleway preference", value: $profile.cyclewayPreference)
            }
            Section {
                Text("Used for route recommendations and safety. Levelling up never changes these.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .navigationTitle("Rider profile")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(profile) } } }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value.wrappedValue)) \(unit)")
            Slider(value: value, in: range)
        }
    }

    private func fraction(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value.wrappedValue * 100))%")
            Slider(value: value, in: 0...1)
        }
    }
}
