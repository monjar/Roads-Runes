import AuthenticationServices
import RoadsAndRunesCore
import SwiftUI

struct SettingsView: View {
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
            Section("Character") {
                Button {
                    changingClass = true
                } label: {
                    HStack {
                        Text("Change class")
                        Spacer()
                        if let character = container.session.character {
                            Text(ClassStyle.name(character.characterClass)).foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                }
                .accessibilityIdentifier("settings.changeClass")
                Text("Your level, XP, coins and discoveries stay. The first change is free; after that it costs Active Coins and waits a day.")
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
            Text("Your character, quests, XP and Active Coins are deleted. Your rides stay in the journal.")
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
