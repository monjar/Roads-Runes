import Foundation
import Observation
import RoadsAndRunesCore

/// Where a `roadsandrunes://` link from a widget, the Live Activity or a
/// Shortcut lands (0.7.3). A quick start goes straight to the app's
/// `QuickStartCoordinator` (which waits, itself, for the app to be ready); a
/// tab to show waits here until the tabs are up to show it.
@MainActor
@Observable
final class DeepLinkInbox {
    static let shared = DeepLinkInbox()

    struct Destination: Identifiable, Equatable {
        let id = UUID()
        let link: DeepLink
    }

    private(set) var destination: Destination?

    /// Hands a quick start on; the coordinator in the app by default, a fake in tests.
    @ObservationIgnored var quickStart: (QuickStart) -> Void = { start in
        QuickStartCoordinator.shared.handle(start, autoStart: false)
    }

    /// A link this inbox understands; false for any other (Strava's return,
    /// which the container takes).
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        open(link)
        return true
    }

    func open(_ link: DeepLink) {
        if case .quickStart(let start) = link {
            quickStart(start)
        } else {
            destination = Destination(link: link)
        }
    }

    /// The tab a link asked for, once.
    func takeDestination() -> DeepLink? {
        defer { destination = nil }
        return destination?.link
    }
}

extension AppTab {
    /// The tab a link opens; nil for one that opens none (the ride is on screen already).
    init?(link: DeepLink) {
        switch link {
        case .world, .bounty: self = .world
        case .quests: self = .quests
        case .ride, .quickStart: return nil
        }
    }
}
