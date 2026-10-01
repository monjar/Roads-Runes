import Foundation

/// Decides when an off-route rider should be given a new route.
///
/// A rider who has drifted a little gets `offRouteDelaySeconds` to drift back;
/// one who is plainly somewhere else (`farMeters`) is not kept waiting. Requests
/// are at least `throttleSeconds` apart, and each one that fails doubles the wait
/// up to `maxBackoffSeconds`, so a planner that cannot be reached is not hammered.
/// All times are the fixes' own, so the decision replays the same from a recording.
public struct RerouteAdvisor: Hashable, Sendable {
    public static let offRouteDelaySeconds: TimeInterval = 8
    public static let farMeters = 150.0
    public static let throttleSeconds: TimeInterval = 15
    public static let maxBackoffSeconds: TimeInterval = 60

    public private(set) var offRouteSince: Date?
    public private(set) var lastRerouteAt: Date?
    public private(set) var consecutiveFailures = 0

    public init(offRouteSince: Date? = nil, lastRerouteAt: Date? = nil) {
        self.offRouteSince = offRouteSince
        self.lastRerouteAt = lastRerouteAt
    }

    /// Seconds that must pass after a request before the next: the throttle, doubled per failure.
    public static func waitSeconds(afterFailures failures: Int) -> TimeInterval {
        min(maxBackoffSeconds, throttleSeconds * pow(2, Double(max(0, failures))))
    }

    /// Pure decision: off route long enough (or far enough), and not too soon after the last request.
    public static func shouldReroute(
        secondsOffRoute: TimeInterval, crossTrackMeters: Double = 0, lastRerouteAt: Date?, failures: Int = 0, now: Date
    ) -> Bool {
        guard secondsOffRoute >= offRouteDelaySeconds || crossTrackMeters >= farMeters else { return false }
        if let last = lastRerouteAt, now.timeIntervalSince(last) < waitSeconds(afterFailures: failures) {
            return false
        }
        return true
    }

    /// Call on every update with the current off-route flag.
    public mutating func observe(isOffRoute: Bool, at now: Date) {
        if isOffRoute {
            if offRouteSince == nil { offRouteSince = now }
        } else {
            offRouteSince = nil
            consecutiveFailures = 0
        }
    }

    public mutating func markOffRoute(at now: Date) { observe(isOffRoute: true, at: now) }
    public mutating func markOnRoute() { observe(isOffRoute: false, at: Date()) }

    public func secondsOffRoute(now: Date) -> TimeInterval {
        guard let since = offRouteSince else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    public func shouldReroute(now: Date, crossTrackMeters: Double = 0) -> Bool {
        guard offRouteSince != nil else { return false }
        return Self.shouldReroute(
            secondsOffRoute: secondsOffRoute(now: now), crossTrackMeters: crossTrackMeters,
            lastRerouteAt: lastRerouteAt, failures: consecutiveFailures, now: now
        )
    }

    /// Record that a reroute was requested.
    public mutating func markRerouted(at now: Date) {
        lastRerouteAt = now
    }

    /// The request came back with nothing: wait longer before the next.
    public mutating func markFailed() {
        consecutiveFailures += 1
    }

    /// A new route was taken: the rider is on it, and the slate is clean.
    public mutating func markSucceeded() {
        consecutiveFailures = 0
        offRouteSince = nil
    }

    /// The rider asked for it themselves: the next decision does not wait on the throttle.
    public mutating func clearThrottle() {
        lastRerouteAt = nil
    }
}
