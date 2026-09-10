import SwiftUI

@main
struct RoadsAndRunesApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .task { await container.bootstrap() }
                .onOpenURL { url in container.handle(url: url) }
        }
    }
}
