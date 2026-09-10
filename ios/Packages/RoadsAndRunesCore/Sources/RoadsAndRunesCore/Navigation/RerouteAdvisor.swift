import Foundation

/// Decides when an off-route rider should get a new route: after
/// `offRouteDelaySeconds` continuously off route, at most once every
/// `throttleSeconds`.
public struct RerouteAdvisor: Hashable, Sendable {
    public static let offRouteDelaySeconds: TimeInterval = 30
    public static let throttleSeconds: TimeInterval = 60

    public private(set) var offRouteSince: Date?
    public private(set) var lastRerouteAt: Date?

    public init(offRouteSince: Date? = nil, lastRerouteAt: Date? = nil) {
        self.offRouteSince = offRouteSince
        self.lastRerouteAt = lastRerouteAt
    }

    /// Pure decision: `true` when off route for at least 30 s and no reroute in the last 60 s.
    public static func shouldReroute(secondsOffRoute: TimeInterval, lastRerouteAt: Date?, now: Date) -> Bool {
        guard secondsOffRoute >= offRouteDelaySeconds else { return false }
        if let last = lastRerouteAt, now.timeIntervalSince(last) < throttleSeconds {
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
        }
    }

    public mutating func markOffRoute(at now: Date) { observe(isOffRoute: true, at: now) }
    public mutating func markOnRoute() { offRouteSince = nil }

    public func secondsOffRoute(now: Date) -> TimeInterval {
        guard let since = offRouteSince else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    public func shouldReroute(now: Date) -> Bool {
        Self.shouldReroute(secondsOffRoute: secondsOffRoute(now: now), lastRerouteAt: lastRerouteAt, now: now)
    }

    /// Record that a reroute was requested; restarts the off-route timer.
    public mutating func markRerouted(at now: Date) {
        lastRerouteAt = now
        offRouteSince = nil
    }
}
