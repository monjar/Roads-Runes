import SwiftUI

@main
struct RoadsAndRunesApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .task { await container.bootstrap() }
                .onOpenURL { url in container.handle(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app is when the reminders are set, from what is true right now.
            guard phase == .background else { return }
            Task { await container.nudges.reschedule(character: container.session.character, activity: container.session.defaultActivity) }
        }
    }
}
