import Foundation
import Snitch
import UIKit

/// What a tester needs to say which build they are on, one long press on the
/// Home Screen icon away (Snitch): the version, the build number TestFlight
/// shows, the server the build talks to and the app's size on the device.
/// Debug and TestFlight builds only; `QA_QUICK_ACTIONS` in project.yml.
enum QAQuickActions {
    static func refresh() {
        guard Config.showsQAQuickActions else {
            UIApplication.shared.shortcutItems = []
            return
        }
        // The size walks Documents, Library (the map's tile cache) and tmp, so
        // it is counted off the main thread and only the result is handed back.
        Task.detached(priority: .utility) {
            // Made here and never touched again until the main thread sets them.
            nonisolated(unsafe) let items = Snitch(options: [.version, .custom(BuildFetcher()), .custom(ServerFetcher()), .size]).shortcutItems
            await MainActor.run { UIApplication.shared.shortcutItems = items }
        }
    }
}

/// The build number, which is what tells two TestFlight builds of one version apart.
private struct BuildFetcher: Fetcher {
    var title: String { "Build" }
    var icon: Icon? { Icon(name: "hammer", kind: .system) }
    func fetch() -> String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
}

/// The backend's host: localhost, a LAN address or the hosted dev server on Fly.
private struct ServerFetcher: Fetcher {
    var title: String { "Server" }
    var icon: Icon? { Icon(name: "server.rack", kind: .system) }
    func fetch() -> String? { Config.apiBaseURL.host }
}
