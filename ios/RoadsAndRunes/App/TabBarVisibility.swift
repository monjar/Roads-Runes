import Observation
import SwiftUI

/// Whether the floating tab bar is showing. Pushed screens that pin their own
/// action bar to the bottom (quest detail, a friend's profile; design 10a)
/// hide it; list-style pushed screens (Friends, Settings) keep it.
@MainActor
@Observable
final class TabBarVisibility {
    /// The screens hiding it, rather than a count: during a push the incoming
    /// screen appears before the outgoing one disappears, and SwiftUI may
    /// repeat either callback, which must not unbalance anything.
    private var hiders: Set<UUID> = []

    var isHidden: Bool { !hiders.isEmpty }

    func hide(for screen: UUID) { hiders.insert(screen) }
    func show(for screen: UUID) { hiders.remove(screen) }
}

private struct HidesTabBar: ViewModifier {
    @Environment(TabBarVisibility.self) private var tabBar: TabBarVisibility?
    @State private var screen = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { tabBar?.hide(for: screen) }
            .onDisappear { tabBar?.show(for: screen) }
    }
}

extension View {
    /// Hides the floating tab bar for as long as this screen is on screen.
    func hidesTabBar() -> some View { modifier(HidesTabBar()) }
}
