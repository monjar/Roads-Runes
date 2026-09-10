import SwiftUI

@main
struct RoadsAndRunesWatchApp: App {
    @State private var container = WatchContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(container)
                .environment(container.store)
        }
    }
}
