import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class CharacterViewModel {
    private(set) var bikes: [Bike] = []
    private(set) var riderProfile: RiderProfile?
    private(set) var stats: ExplorationStats?
    var error: String?
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    var character: Character? { container.session.character }

    func load() async {
        await container.session.refreshCharacter()
        bikes = (try? await container.api.bikes()) ?? []
        riderProfile = try? await container.api.riderProfile()
        stats = try? await container.api.explorationStats()
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

/// Character sheet (design 11b): heraldic mark, level and class XP, abilities,
/// and beneath it a clearly separate Cycling Profile that keeps rides suitable.
struct CharacterView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: CharacterViewModel?
    @State private var editingBike: Bike?
    @State private var addingBike = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.Colors.cream.ignoresSafeArea()
                ClassStyle.color(model?.character?.characterClass ?? .explorer)
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    .ignoresSafeArea(edges: .top)
                ScrollView(showsIndicators: false) {
                    if let model {
                        VStack(spacing: 0) {
                            if let character = model.character {
                                CharacterHeader(character: character)
                            }
                            sheet(model)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model?.load() }
            .sheet(item: $editingBike) { bike in BikeEditorView(bike: bike) { input in Task { await model?.save(bike: input, id: bike.id) } } onDelete: { Task { await model?.delete(bike: bike) } } }
            .sheet(isPresented: $addingBike) { BikeEditorView(bike: nil) { input in Task { await model?.save(bike: input, id: nil) } } onDelete: {} }
        }
        .task {
            if model == nil { model = CharacterViewModel(container: container) }
            await model?.load()
        }
    }

    @ViewBuilder
    private func sheet(_ model: CharacterViewModel) -> some View {
        let character = model.character
        let classColor = ClassStyle.color(character?.characterClass ?? .explorer)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                FactTile(value: exploredArea(model.stats), label: "Explored")
                FactTile(value: "\(model.stats?.discoveriesFound ?? 0)", label: "Discoveries")
                FactTile(value: "\(model.stats?.questsCompleted ?? 0)", label: "Quests")
            }
            if let error = model.error { ErrorLine(text: error) }

            let abilities = character?.abilities ?? []
            SectionHeader(title: "Abilities", subtitle: "\(abilities.filter(\.unlocked).count) of \(abilities.count) unlocked")
            FlowLayout(spacing: 8) {
                ForEach(abilities) { state in
                    AbilityCard(state: state, color: classColor) { Task { await model.unlock(state) } }
                }
            }
            if let points = character?.unspentAbilityPoints, points > 0 {
                Text("\(points) ability point\(points == 1 ? "" : "s") to spend · tap an outlined ability")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
            }

            cyclingProfile(model)

            SectionHeader(title: "Bikes")
            ForEach(model.bikes) { bike in
                Button { editingBike = bike } label: { bikeRow(bike) }.buttonStyle(.plain)
            }
            Button { addingBike = true } label: { Label("Add a bike", systemImage: "plus") }.buttonStyle(.surfacePill)

            SectionHeader(title: "More")
            NavigationLink { FriendsView() } label: { moreRow("Friends", symbol: "person.2.fill") }.buttonStyle(.plain)
            NavigationLink { IntegrationsView() } label: { moreRow("Health & Strava", symbol: "heart.fill") }.buttonStyle(.plain)
            NavigationLink { SettingsView() } label: { moreRow("Settings", symbol: "gearshape.fill") }.buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheetSurface()
        .offset(y: -26)
    }

    private func exploredArea(_ stats: ExplorationStats?) -> String {
        let area = Double(stats?.cellsVisited ?? 0) * 0.1053
        return area >= 10 ? "\(Int(area.rounded())) km²" : String(format: "%.1f km²", area)
    }

    @ViewBuilder
    private func cyclingProfile(_ model: CharacterViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cycling profile").font(Theme.Typography.label).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Text("Keeps quests suitable · separate from your level")
                    .font(Theme.Typography.text(11.5, relativeTo: .caption2)).foregroundStyle(Theme.Colors.muted).multilineTextAlignment(.trailing)
            }
            if let profile = model.riderProfile {
                let defaultBike = model.bikes.first { $0.isDefault } ?? model.bikes.first
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    profileLine("Typical ride", "\(Int(profile.comfortableDistanceKm * 0.7))–\(Int(profile.comfortableDistanceKm * 1.3)) km")
                    profileLine("Climbing", level(profile.comfortableElevationGain / 1200))
                    profileLine("Gravel", level(profile.gravelComfort))
                    profileLine("Traffic", level(profile.trafficTolerance))
                    profileLine("Bike", defaultBike?.name ?? "—")
                    NavigationLink {
                        RiderProfileView(profile: profile) { updated in Task { await model.save(profile: updated) } }
                    } label: {
                        Text("Adjust ›").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                    }
                }
            } else {
                Text("Learned from your rides.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
        .card()
    }

    private func profileLine(_ title: String, _ value: String) -> some View {
        (Text("\(title) ").foregroundStyle(Theme.Colors.inkSoft) + Text(value).font(Theme.Typography.text(12.5, .bold, relativeTo: .caption)).foregroundStyle(Theme.Colors.ink))
            .font(Theme.Typography.caption)
            .lineLimit(1)
    }

    private func level(_ fraction: Double) -> String {
        switch fraction {
        case ..<0.34: return "Low"
        case ..<0.67: return "Medium"
        default: return "High"
        }
    }

    private func bikeRow(_ bike: Bike) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.Colors.cream)
                Image(systemName: "bicycle").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.Colors.ink)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(bike.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                Text("\(bike.bikeType.rawValue.capitalized)\(bike.isDefault ? " · default" : "")\(bike.allowGravel ? " · gravel ok" : "")")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private func moreRow(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.Colors.ink).frame(width: 24)
            Text(title).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
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
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.cream)
            .tint(Theme.Colors.terracotta)
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
                Text("Used for route recommendations and safety. Levelling up never changes these.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Colors.cream)
        .tint(Theme.Colors.terracotta)
        .navigationTitle("Cycling profile")
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
