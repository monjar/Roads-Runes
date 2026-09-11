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
                    // A new character: bike, then location, then the world.
                    switch step {
                    case .location:
                        LocationPermissionView(onDone: { container.session.finishOnboarding() })
                    default:
                        BikeSetupView(onDone: { step = .location })
                    }
                }
            }
            .background(Theme.Colors.cream.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct WelcomeView: View {
    @Environment(AppContainer.self) private var container
    @State private var devSubject = "rider-1"

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle().fill(Theme.Colors.sage).frame(width: 112, height: 112)
                Circle().stroke(Theme.Colors.sage.opacity(0.35), lineWidth: 1.5).frame(width: 140, height: 140)
                Circle().stroke(Theme.Colors.sage.opacity(0.18), lineWidth: 1).frame(width: 172, height: 172)
                Image(systemName: "sparkle").font(.system(size: 52, weight: .bold)).foregroundStyle(Theme.Colors.cream)
            }
            .padding(.bottom, 8)
            Text("Roads & Runes").font(Theme.Typography.voice(40, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
            Text("An RPG where the real world is the map\nand your bicycle is how you explore it.")
                .font(Theme.Typography.text(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.Colors.muted)
                .lineSpacing(3)
            Spacer()
            if Config.allowsAppleSignIn {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    Task { await container.session.signInWithApple(result: result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(Capsule())
                .padding(.horizontal, 22)
            } else {
                Text("Sign in with Apple needs a paid Apple developer account, so this build leaves it out.")
                    .font(Theme.Typography.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Colors.muted)
                    .padding(.horizontal, 32)
            }
            if Config.allowsDevSignIn {
                VStack(spacing: Theme.Spacing.sm) {
                    TextField("Developer subject", text: $devSubject).textFieldStyle(CreamFieldStyle()).padding(.horizontal, 22)
                    Button("Developer sign in") {
                        Task { await container.session.devSignIn(subject: devSubject, displayName: "Dev Rider") }
                    }
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Colors.terracottaDeep)
                }
            }
            if let error = container.session.lastError {
                ErrorLine(text: error).padding(.horizontal, 22)
            }
            Spacer().frame(height: Theme.Spacing.lg)
        }
    }
}

/// Surface-coloured pill text field.
struct CreamFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(Theme.Typography.text(16))
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Theme.Colors.surface, in: Capsule())
    }
}

/// "How do you like to explore?" (design 11a): four heraldic cards, each with
/// its fantasy in one line and how it plays. Any class can take any quest.
struct CharacterCreationView: View {
    @Environment(AppContainer.self) private var container
    let onDone: () -> Void
    @State private var name = ""
    @State private var selected: CharacterClass = .explorer
    @State private var classes: [ClassInfo] = []
    @State private var saving = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How do you\nlike to explore?").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                    Text("Your class shapes your quests and bonuses. It never locks you out of anything.")
                        .font(Theme.Typography.text(13.5)).foregroundStyle(Theme.Colors.muted).lineSpacing(2)
                    TextField("Your name", text: $name).textFieldStyle(CreamFieldStyle()).padding(.vertical, 4)
                    ForEach(classes) { info in
                        let value = info.characterClass
                        Button {
                            if info.enabled { withAnimation(.snappy) { selected = value } }
                        } label: {
                            ClassCard(info: info, selected: selected == value && info.enabled)
                        }
                        .buttonStyle(.pressable)
                    }
                    if let error = container.session.lastError { ErrorLine(text: error) }
                }
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 110)
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
                Text(saving ? "Creating…" : "Ride as \(article(for: selected)) \(ClassStyle.name(selected))")
            }
            .buttonStyle(.primary)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .task {
            classes = (try? await container.api.classes()) ?? [
                ClassInfo(id: "EXPLORER", name: "Explorer", tagline: "Chart unknown territory.", description: "New roads and unvisited areas earn the most.", enabled: true),
            ]
        }
    }

    private func article(for characterClass: CharacterClass) -> String {
        characterClass == .explorer ? "an" : "a"
    }
}

struct ClassCard: View {
    let info: ClassInfo
    let selected: Bool

    var body: some View {
        let characterClass = info.characterClass
        HStack(spacing: 14) {
            ClassEmblem(characterClass: characterClass, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(info.name).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    if selected {
                        Eyebrow(text: "Chosen", color: Theme.Colors.sageDeep)
                    } else if !info.enabled {
                        Eyebrow(text: "Coming soon", color: Theme.Colors.muted)
                    }
                }
                Text(info.tagline).font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft).lineSpacing(2)
                Text(info.description).font(Theme.Typography.text(11.5, relativeTo: .caption2)).foregroundStyle(Theme.Colors.muted).lineLimit(2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(selected ? ClassStyle.color(characterClass) : .clear, lineWidth: 2))
        .opacity(info.enabled ? 1 : 0.55)
    }
}

struct BikeSetupView: View {
    @Environment(AppContainer.self) private var container
    let onDone: () -> Void
    @State private var name = "My bike"
    @State private var type: BikeType = .gravel
    @State private var saving = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Cycling profile", color: Theme.Colors.sageDeep)
                Text("Your bike").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                Text("Routing respects what your bike can ride. It keeps quests suitable and never changes your level.")
                    .font(Theme.Typography.text(13.5)).foregroundStyle(Theme.Colors.muted).lineSpacing(2)
                TextField("Bike name", text: $name).textFieldStyle(CreamFieldStyle())
                FlowLayout(spacing: 8) {
                    ForEach([BikeType.road, .gravel, .mountain, .hybrid, .folding, .other], id: \.self) { value in
                        Button(value.rawValue.capitalized) { type = value }
                            .buttonStyle(InkPillButtonStyle(selected: type == value))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            Button {
                saving = true
                Task {
                    _ = try? await container.api.createBike(BikeIn(name: name, bikeType: type, isDefault: true))
                    saving = false
                    onDone()
                }
            } label: { Text("Continue") }
                .buttonStyle(.primary)
                .disabled(saving)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
        }
    }
}

struct LocationPermissionView: View {
    @Environment(AppContainer.self) private var container
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()
            ZStack {
                Circle().fill(Theme.Colors.surface).frame(width: 112, height: 112)
                Circle().fill(Theme.Colors.sage).frame(width: 26, height: 26)
                Circle().stroke(Theme.Colors.sage.opacity(0.35), lineWidth: 10).frame(width: 52, height: 52)
            }
            Text("Your position is\nyour character").font(Theme.Typography.voice(30, relativeTo: .largeTitle)).multilineTextAlignment(.center).foregroundStyle(Theme.Colors.ink)
            Text(
                "Roads & Runes needs your location to draw the world map, the fog around you and the quests nearby. " +
                "During a ride it records your route in the background so the map clears and objectives complete even when your phone is locked. " +
                "Your live location is never shared."
            )
            .font(Theme.Typography.text(14))
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.Colors.muted)
            .lineSpacing(3)
            .padding(.horizontal, 22)
            Spacer()
            Button {
                container.location.requestWhenInUse()
                onDone()
            } label: { Text("Allow location") }
                .buttonStyle(.primary)
                .padding(.horizontal, 20)
            Button("Not now", action: onDone).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
            Spacer().frame(height: Theme.Spacing.lg)
        }
    }
}
