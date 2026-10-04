import AuthenticationServices
import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

struct SettingsView: View {
    /// Everyone whose icons the game draws, for the credits.
    static let iconAuthors: String = {
        let names = Array(Set(GameIcon.allCases.map(\.author))).sorted()
        return names.dropLast().joined(separator: ", ") + (names.count > 1 ? " and " : "") + (names.last ?? "")
    }()

    @Environment(AppContainer.self) private var container
    @State private var settings = UserSettings()
    @State private var changingClass = false
    @State private var confirmingReset = false
    @State private var resetting = false

    var body: some View {
        Form {
            Section("Riding") {
                Picker("Battery mode", selection: $settings.batteryMode) {
                    ForEach([BatteryMode.full, .balanced, .endurance], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Map style", selection: $settings.mapStyle) {
                    ForEach([MapStyle.minimal, .cycling, .adventure, .detailed], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Units", selection: $settings.units) {
                    Text("Metric").tag(Units.metric); Text("Imperial").tag(Units.imperial)
                }
            }
            Section("Sound on a ride") {
                Picker("Sound", selection: Binding(
                    get: { container.mapPreferences.rideSound },
                    set: { sound in
                        container.mapPreferences.rideSound = sound
                        container.rideAudio.preview(sound)
                    }
                )) {
                    ForEach(RideSound.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.rideSound")
                Text("A chime for a chest, a thing seen off, a new place, halfway; new ground climbs a scale. The voice says the same things in a few words, and turns your music down while it does. Both play with the phone on silent.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                // For the road test: hear a fight, and feel it on the Watch, before meeting one.
                Button("Hear a fight") {
                    container.rideAudio.playScriptedFight { beat in
                        container.watch.send(encounterBeat: WatchEncounterBeat(beat: beat, name: "Grey Stag"))
                    }
                }
                .disabled(container.mapPreferences.rideSound == .off)
                .accessibilityIdentifier("settings.hearAFight")
            }
            Section("Privacy") {
                Picker("New rides are", selection: $settings.defaultRideVisibility) {
                    Text("Private").tag(RoadsAndRunesCore.Visibility.privateOnly)
                    Text("Friends").tag(RoadsAndRunesCore.Visibility.friends)
                    Text("Public").tag(RoadsAndRunesCore.Visibility.publicAll)
                }
                Text("Your live location and ride start/end points are never shown to anyone.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Section("Strava") {
                Picker("Upload rides", selection: $settings.stravaUploadMode) {
                    Text("Never").tag(StravaUploadMode.never); Text("Ask every time").tag(StravaUploadMode.ask); Text("Automatically").tag(StravaUploadMode.auto)
                }
            }
            Section("Reminders") {
                Toggle("Days kept and bounty reminders", isOn: Binding(
                    get: { container.nudges.isEnabled },
                    set: { enabled in
                        container.nudges.isEnabled = enabled
                        if enabled { Task { await container.nudges.requestAuthorizationIfNeeded() } }
                    }
                ))
                Text("One in the evening if a run of days kept is about to end, one in the morning when the day's bounty is out. Nothing else, and nothing leaves your phone.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Section("Character") {
                Button {
                    changingClass = true
                } label: {
                    HStack {
                        Text(LoreCopy.changeOfTrade)
                        Spacer()
                        if let character = container.session.character {
                            Text(ClassStyle.name(character.characterClass)).foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                }
                .accessibilityIdentifier("settings.changeClass")
                Text("Your level, XP, coins and discoveries stay. The first change of trade is free; after that it costs coins and waits a day.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                Button("Start over", role: .destructive) { confirmingReset = true }
                    .disabled(resetting)
                    .accessibilityIdentifier("settings.startOver")
                Text("Deletes your character, quests, XP and coins and picks a class again. Your rides stay in the journal.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Section {
                Button("Save") { Task { await container.session.update(settings: settings); container.mapPreferences.apply(settings: settings) } }
                Button("Sign out", role: .destructive) { Task { await container.session.signOut() } }
            }
            Section("Credits") {
                // CC BY 3.0 asks for this: who drew the pictures, and where they are from.
                Text("Icons by \(Self.iconAuthors) from game-icons.net, under CC BY 3.0.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                Link("game-icons.net", destination: URL(string: "https://game-icons.net")!)
                    .font(Theme.Typography.caption)
            }
        }
        .navigationTitle("Settings")
        .onAppear { settings = container.session.settings }
        .sheet(isPresented: $changingClass) { ClassChangeSheet() }
        .confirmationDialog("Start over?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete my character and start over", role: .destructive) {
                resetting = true
                Task {
                    _ = await container.session.resetCharacter()
                    resetting = false
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Your character, quests, XP and coins are deleted. Your rides stay in the journal.")
        }
    }
}

struct IntegrationsView: View {
    @Environment(AppContainer.self) private var container
    @State private var strava: StravaStatus?
    @State private var error: String?
    @State private var authSession: ASWebAuthenticationSession?
    @State private var presenter = WebAuthPresenter()

    var body: some View {
        Form {
            Section("Health") {
                HStack {
                    Text("HealthKit")
                    Spacer()
                    Text(container.health.isAuthorized ? "Connected" : (container.health.isAvailable ? "Not connected" : "Unavailable")).foregroundStyle(Theme.Colors.textSecondary)
                }
                if !container.health.isAuthorized && container.health.isAvailable {
                    Button("Connect Health") { Task { await container.health.requestAuthorization() } }
                }
                Text("Outings are saved as cycling, running or walking workouts with route and heart rate. The app works fully without Health.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Section("Strava") {
                if let strava {
                    HStack { Text("Status"); Spacer(); Text(strava.connected ? (strava.athleteName ?? "Connected") : "Not connected").foregroundStyle(Theme.Colors.textSecondary) }
                    if strava.enabled == false {
                        Text("Strava is not enabled on this server yet.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                    } else if strava.connected {
                        Button("Disconnect", role: .destructive) { Task { try? await container.api.disconnectStrava(); await load() } }
                    } else {
                        Button("Connect Strava") { Task { await connect() } }
                    }
                } else { ProgressView() }
                if let error { Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember) }
            }
        }
        .navigationTitle("Integrations")
        .task { await load() }
        .onChange(of: container.pendingStravaCode) { _, code in
            guard let code else { return }
            container.pendingStravaCode = nil
            Task { strava = try? await container.api.stravaCallback(code: code) }
        }
    }

    private func load() async {
        do { strava = try await container.api.stravaStatus() } catch { self.error = error.localizedDescription }
    }

    private func connect() async {
        do {
            let response = try await container.api.stravaAuthorize()
            guard let url = URL(string: response.url) else { return }
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "roadsandrunes") { callback, _ in
                guard let callback else { return }
                Task { @MainActor in container.handle(url: callback) }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            session.start()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
