import Foundation
import RoadsAndRunesCore
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Where the Live Activity goes. ActivityKit on a device; a fake in tests.
@MainActor
protocol RideActivitySink: AnyObject {
    /// Starts one, ending any left from before (a crash, an older run).
    func start(_ attributes: RideActivityAttributes, state: RideActivityState, staleAfter: TimeInterval)
    func update(_ state: RideActivityState, staleAfter: TimeInterval)
    /// Ends every one; `state` is the last thing shown, for the moment it stays.
    func endAll(_ state: RideActivityState?)
    /// Whether one is showing (or left over from a previous launch).
    var isRunning: Bool { get }
}

/// The journey on the lock screen and in the Dynamic Island (0.7.3). `RideRecorder`
/// calls it beside the Watch: `begin` with the route summary, `update` with each
/// navigation update (sent at most every few seconds, at once on a new turn),
/// and the last update, completed or cancelled, ends it.
@MainActor
final class RideActivityController {
    static let shared = RideActivityController(sink: RideActivityController.defaultSink())

    /// A lock screen still showing this long after the last update is marked stale.
    static let staleAfter: TimeInterval = 120

    private let sink: RideActivitySink?
    private var throttle = RideActivityThrottle()
    private var attributes: RideActivityAttributes?

    init(sink: RideActivitySink?) {
        self.sink = sink
    }

    /// Starts the activity for a journey (or keeps the one already showing, on a
    /// new route or after a resume).
    func begin(activity: RoadsAndRunesCore.Activity, questTitle: String?, units: Units) {
        guard let sink else { return }
        let attributes = RideActivityAttributes(activity: (activity == .unknown ? RoadsAndRunesCore.Activity.ride : activity).rawValue,
                                                questTitle: questTitle, units: units.rawValue)
        if self.attributes == attributes, sink.isRunning { return }
        self.attributes = attributes
        throttle.reset()
        let first = RideActivityState()
        _ = throttle.shouldSend(first)
        sink.start(attributes, state: first, staleAfter: Self.staleAfter)
    }

    /// The navigation update the Watch is sent, for the lock screen too.
    func update(_ update: WatchNavigationUpdate, at now: Date = Date()) {
        guard let sink else { return }
        let state = RideActivityState(update: update)
        if update.state.isTerminal {
            end(state)
            return
        }
        guard attributes != nil, throttle.shouldSend(state, at: now) else { return }
        sink.update(state, staleAfter: Self.staleAfter)
    }

    /// Ends it: the journey was saved or discarded, or a crashed one was given up.
    func end(_ last: RideActivityState? = nil) {
        guard let sink else { return }
        attributes = nil
        throttle.reset()
        sink.endAll(last)
    }

    // MARK: -

    private static func defaultSink() -> RideActivitySink? {
        // Unit tests and previews put nothing on the lock screen.
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return nil }
        #if canImport(ActivityKit)
        return ActivityKitSink()
        #else
        return nil
        #endif
    }
}

#if canImport(ActivityKit)
/// The real lock screen. Every call is fire-and-forget: a Live Activity the
/// system refuses (switched off in Settings, too many) never stops a journey.
@MainActor
final class ActivityKitSink: RideActivitySink {
    private var current: ActivityKit.Activity<RideActivityAttributes>?

    var isRunning: Bool {
        current.map { $0.activityState == .active || $0.activityState == .stale } ?? false
    }

    func start(_ attributes: RideActivityAttributes, state: RideActivityState, staleAfter: TimeInterval) {
        let leftovers = ActivityKit.Activity<RideActivityAttributes>.activities
        Task { for old in leftovers { await old.end(nil, dismissalPolicy: .immediate) } }
        current = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
        current = try? ActivityKit.Activity.request(attributes: attributes, content: content, pushType: nil)
    }

    func update(_ state: RideActivityState, staleAfter: TimeInterval) {
        guard let current else { return }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleAfter))
        Task { await current.update(content) }
    }

    func endAll(_ state: RideActivityState?) {
        let all = ActivityKit.Activity<RideActivityAttributes>.activities
        current = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        Task { for activity in all { await activity.end(content, dismissalPolicy: .immediate) } }
    }
}
#endif
