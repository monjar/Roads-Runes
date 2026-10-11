import Foundation

/// When a journey with no route asks for the world round it again (0.9.2, Ride
/// anywhere, `GET /world/around`): once it is 1.5 km from where the last answer was
/// for, and never sooner than 90 s after the last ask. Never while paused, and
/// never two at once. A failure waits 30 s, then 60, 120… up to 10 minutes before
/// the next try (the ride falls back on the last world kept meanwhile). While the
/// server says places round here are still being fetched, it asks again after the
/// 90 s even without moving, a few times; and once, 90 s after the start, in case the
/// start was ground whose places had not arrived yet.
///
/// Pure: it is told the time and where the rider is, and keeps no clock of its own.
public struct RoamRefresher: Hashable, Sendable {
    public static let everyMeters = 1500.0
    public static let minimumSeconds: TimeInterval = 90
    public static let firstBackoffSeconds: TimeInterval = 30
    public static let longestBackoffSeconds: TimeInterval = 600
    /// Asks made without moving while places are still coming, before it waits for distance again.
    public static let importingRetries = 3

    /// Where the last good answer was for.
    public private(set) var refreshedFrom: Coordinate?
    /// When the last ask went (or the world was first loaded).
    public private(set) var lastAskedAt: Date?
    public private(set) var failures = 0
    public private(set) var inFlight = false
    private var askingFrom: Coordinate?
    private var askedOnTheMove = false
    private var retriesLeft = 0

    public init() {}

    /// The world round the start was loaded at `now`: one look again in 90 s, then 1.5 km on.
    public mutating func loaded(from position: Coordinate, at now: Date) {
        refreshedFrom = position
        lastAskedAt = now
        failures = 0
        inFlight = false
        retriesLeft = 1
    }

    /// Whether to ask now, from `position`.
    public func shouldRefresh(from position: Coordinate, at now: Date, paused: Bool) -> Bool {
        guard !paused, !inFlight else { return false }
        guard let lastAskedAt else { return true }
        let waited = now.timeIntervalSince(lastAskedAt)
        if failures > 0 { return waited >= backoffSeconds }
        guard waited >= Self.minimumSeconds else { return false }
        guard let refreshedFrom else { return true }
        return retriesLeft > 0 || GeoMath.distance(refreshedFrom, position) >= Self.everyMeters
    }

    /// How long after a failure the next try waits.
    public var backoffSeconds: TimeInterval {
        guard failures > 0 else { return 0 }
        return min(Self.longestBackoffSeconds, Self.firstBackoffSeconds * pow(2, Double(failures - 1)))
    }

    /// An ask has gone from `position` at `now`.
    public mutating func began(from position: Coordinate, at now: Date) {
        inFlight = true
        askingFrom = position
        askedOnTheMove = refreshedFrom.map { GeoMath.distance($0, position) >= Self.everyMeters } ?? true
        lastAskedAt = now
    }

    /// The answer came. `importing`: the server is still fetching places round there.
    public mutating func succeeded(importing: Bool) {
        inFlight = false
        failures = 0
        if let askingFrom { refreshedFrom = askingFrom }
        askingFrom = nil
        // A few asks without moving while places are coming, counted from the last one made on the move.
        retriesLeft = importing ? (askedOnTheMove ? Self.importingRetries : max(0, retriesLeft - 1)) : max(0, retriesLeft - 1)
    }

    /// No answer (no signal, a server error, or the flag off): try again after the backoff.
    public mutating func failed() {
        inFlight = false
        failures += 1
        askingFrom = nil
    }
}
