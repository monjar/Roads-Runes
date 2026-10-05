import SwiftUI

@main
struct RoadsAndRunesApp: App {
    @State private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .task {
                    // The widgets' snapshot is written from this container (0.7.3).
                    WidgetSnapshotWriter.shared.attach(container)
                    await container.bootstrap()
                }
                // A widget, the Live Activity or a Shortcut (0.7.3); anything else (Strava) is the container's.
                .onOpenURL { url in
                    if !DeepLinkInbox.shared.open(url) { container.handle(url: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the app is when the reminders are set, from what is true right now.
            guard phase == .background else { return }
            WidgetSnapshotWriter.shared.appBackgrounded()
            Task { await container.nudges.reschedule(character: container.session.character, activity: container.session.defaultActivity, units: container.session.units) }
        }
    }
}
