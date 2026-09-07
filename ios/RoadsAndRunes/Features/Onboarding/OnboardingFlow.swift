import AuthenticationServices
import RoadsAndRunesCore
import SwiftUI

/// Welcome → Sign in → Character → Bike → Location permission (spec §96 steps 1–5).
struct OnboardingFlow: View {
    @Environment(AppContainer.self) private var container
    @State private var step: Step = .welcome

    enum Step { case welcome, character, bike, location }

    var body: some View {
        NavigationStack {
            Group {
                switch container.session.state {
                case .signedOut:
                    WelcomeView()
                case .needsCharacter:
                    CharacterCreationView(onDone: { step = .bike })
                default:
                    switch step {
                    case .bike:
                        BikeSetupView(onDone: { step = .location })
                    case .location:
                        LocationPermissionView(onDone: { step = .welcome })
                    default:
                        EmptyView()
                    }
                }
            }
            .background(Theme.Colors.parchment.ignoresSafeArea())
        }
    }
}

struct WelcomeView: View {
    @Environment(AppContainer.self) private var container
    @State private var devSubject = "rider-1"

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "map.fill").font(.system(size: 64)).foregroundStyle(Theme.Colors.moss)
            Text("Roads & Runes").font(Theme.Typography.display)
            Text("An RPG where the real world is the map and your bicycle is how you explore it.")
                .font(Theme.Typography.body).multilineTextAlignment(.center).foregroundStyle(Theme.Colors.textSecondary)
                .padding(.horizontal, Theme.Spacing.xl)
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName]
            } onCompletion: { result in
                Task { await container.session.signInWithApple(result: result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 52)
            .padding(.horizontal, Theme.Spacing.lg)
            if Config.allowsDevSignIn {
                VStack(spacing: Theme.Spacing.sm) {
                    TextField("Developer subject", text: $devSubject).textFieldStyle(.roundedBorder).padding(.horizontal, Theme.Spacing.lg)
                    Button("Developer sign in") {
                        Task { await container.session.devSignIn(subject: devSubject, displayName: "Dev Rider") }
                    }
                    .font(Theme.Typography.caption)
                }
            }
            if let error = container.session.lastError {
                Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember).padding(.horizontal)
            }
            Spacer().frame(height: Theme.Spacing.lg)
        }
    }
}

struct CharacterCreationView: View {
    @Environment(AppContainer.self) private var container
    let onDone: () -> Void
    @State private var name = ""
    @State private var selected: CharacterClass = .explorer
    @State private var classes: [ClassInfo] = []
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("STEP 2 OF 3").font(Theme.Typography.caption.weight(.bold)).foregroundStyle(Theme.Colors.textSecondary)
                Text("Create your character").font(Theme.Typography.display)
                TextField("Character name", text: $name).textFieldStyle(.roundedBorder)
                Text("Choose your class").font(Theme.Typography.title)
                Text("Your class shapes the quests the world offers you.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                ForEach(classes) { info in
                    let value = CharacterClass(rawValue: info.id) ?? .unknown
                    Button {
                        if info.enabled { selected = value }
                    } label: {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack {
                                Text(info.name).font(Theme.Typography.heading)
                                Spacer()
                                if !info.enabled {
                                    Label("Coming soon", systemImage: "lock").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                                } else if selected == value {
                                    Text("SELECTED").font(Theme.Typography.caption.weight(.bold)).foregroundStyle(Theme.Colors.moss)
                                }
                            }
                            Text(info.description).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                        }
                        .card()
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(selected == value && info.enabled ? Theme.Colors.moss : .clear, lineWidth: 2))
                        .opacity(info.enabled ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    saving = true
                    Task {
                        if await container.session.createCharacter(name: name.trimmingCharacters(in: .whitespaces), characterClass: selected) {
                            onDone()
                        }
                        saving = false
                    }
                } label: {
                    Text(saving ? "Creating…" : "Continue as \(selected.rawValue.capitalized)").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Colors.moss)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                if let error = container.session.lastError {
                    Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .task {
            classes = (try? await container.api.classes()) ?? [
                ClassInfo(id: "EXPLORER", name: "Explorer", tagline: "Rewards discovering new territory.", description: "Cycle new roads, visit new neighbourhoods, discover trails, parks and viewpoints.", enabled: true),
            ]
        }
    }
}

struct BikeSetupView: View {
    @Environment(AppContainer.self) private var container
    let onDone: () -> Void
    @State private var name = "My bike"
    @State private var type: BikeType = .gravel
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("STEP 3 OF 3").font(Theme.Typography.caption.weight(.bold)).foregroundStyle(Theme.Colors.textSecondary)
            Text("Your bike").font(Theme.Typography.display)
            Text("Routing respects what your bike can ride. It never changes your level.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            TextField("Bike name", text: $name).textFieldStyle(.roundedBorder)
            Picker("Type", selection: $type) {
                ForEach([BikeType.road, .gravel, .mountain, .hybrid, .folding, .other], id: \.self) { value in
                    Text(value.rawValue.capitalized).tag(value)
                }
            }
            .pickerStyle(.segmented)
            Spacer()
            Button {
                saving = true
                Task {
                    _ = try? await container.api.createBike(BikeIn(name: name, bikeType: type, isDefault: true))
                    saving = false
                    onDone()
                }
            } label: { Text("Continue").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Colors.moss).disabled(saving)
        }
        .padding(Theme.Spacing.md)
    }
}

struct LocationPermissionView: View {
    @Environment(AppContainer.self) private var container
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            Image(systemName: "location.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.Colors.river)
            Text("Your position is your character").font(Theme.Typography.title).multilineTextAlignment(.center)
            Text(
                "Roads & Runes needs your location to show the world map, the fog around you and the quests nearby. " +
                "During a ride it records your route in the background so the map clears and objectives complete even when your phone is locked. " +
                "We never share your live location."
            )
                .font(Theme.Typography.body).multilineTextAlignment(.center).foregroundStyle(Theme.Colors.textSecondary).padding(.horizontal, Theme.Spacing.lg)
            Spacer()
            Button {
                container.location.requestWhenInUse()
                onDone()
            } label: { Text("Allow location").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Colors.moss).padding(.horizontal, Theme.Spacing.lg)
            Button("Not now", action: onDone).font(Theme.Typography.caption)
            Spacer().frame(height: Theme.Spacing.lg)
        }
    }
}
