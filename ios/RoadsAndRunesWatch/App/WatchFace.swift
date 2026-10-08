import Foundation
import RoadsAndRunesCore
import WidgetKit

/// Keeps the complication in step (0.7.3): writes Next up and the quarry of the
/// journey under way into the app group the widget extension reads, and asks for
/// new timelines only when something there changed.
@MainActor
final class ComplicationWriter {
    private let defaults: UserDefaults?
    private let reload: () -> Void

    init(defaults: UserDefaults? = WatchIdleStore.sharedDefaults,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.defaults = defaults
        self.reload = reload
    }

    /// Next up is kept when none is given (the last word stands); the quarry is
    /// cleared when no journey is under way.
    func publish(idle: WatchIdleInfo?, quarry: WatchQuarry?) {
        let idleChanged = idle.map { WatchIdleStore.write(idle: $0, to: defaults) } ?? false
        let quarryChanged = WatchIdleStore.write(quarry: quarry, to: defaults)
        if idleChanged || quarryChanged { reload() }
    }

    /// Next up as last kept, for the idle screen at launch.
    func keptIdle() -> WatchIdleInfo? {
        WatchIdleStore.readIdle(from: defaults)
    }
}
