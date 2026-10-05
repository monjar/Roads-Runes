import Foundation

// Districts on the wrist (0.9.0): the phone learns which district the rider is
// in and sends it with each navigation update (`WatchNavigationUpdate.districtName`);
// the Watch names each one once a journey, at a standstill, never while moving.
// Journey's end says which districts the journey made yours and which it
// completed (`WatchJourneyEnd.districts`, `.completedDistricts`). All of it is
// optional on the wire, so a phone or a Watch a release behind reads the other.

/// The phone's side: which district the rider is in, asked of the server
/// (`GET /districts/here`) at most once a minute and only once the rider has
/// moved more than 300 m since the last ask. The ride never waits on it: the
/// last answer stands until the next. One lookout lives for one journey.
public struct DistrictLookout: Sendable {
    /// At most one question this often.
    public static let interval: TimeInterval = 60
    /// And only once the rider is this far from where the last one was asked.
    public static let movedMeters = 300.0

    /// The district the rider was in at the last answer, with its title
    /// ("Rotherhithe, the Riverlands"); nil before one, or outside every district.
    public private(set) var name: String?
    private var lastAsked: (at: Date, from: Coordinate)?
    private var waiting = false

    public init() {}

    /// Whether to ask now, from here. A yes counts as asked: the answer comes to
    /// `answered` or `failed`, and nothing more is asked until it does.
    public mutating func shouldAsk(from position: Coordinate, at now: Date) -> Bool {
        guard !waiting else { return false }
        if let lastAsked {
            guard now.timeIntervalSince(lastAsked.at) >= Self.interval,
                  GeoMath.distance(lastAsked.from, position) > Self.movedMeters else { return false }
        }
        lastAsked = (now, position)
        waiting = true
        return true
    }

    /// The server's answer: the district here with its title, or none.
    public mutating func answered(_ name: String?) {
        waiting = false
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.name = trimmed.isEmpty ? nil : trimmed
    }

    /// No answer (no signal, an error): the last one stands, and the next ask
    /// waits for its minute and its 300 m like any other.
    public mutating func failed() {
        waiting = false
    }
}

/// The Watch's side: a district is named at the next standstill (Core
/// `Stillness`: under 0.7 m/s for five seconds), never while moving, and once a
/// journey. It stays while the rider stands and goes when they move off. The
/// phone's updates stop coming when the rider does, so the line is asked for
/// by the clock (`line(at:)`) between them.
public struct DistrictNaming: Sendable {
    private var stillness = Stillness()
    /// The district the rider is in, not named yet on this journey.
    public private(set) var waiting: String?
    /// The district named at this standstill.
    private var showing: String?
    /// Every district named on this journey.
    public private(set) var named: Set<String> = []

    public init() {}

    /// Each navigation update: the district it names and the speed it carries, by
    /// the time it came.
    public mutating func update(district: String?, speedMps: Double?, at time: Date) {
        // Still since before this update: what was waiting has been on screen.
        if stillness.isStill(at: time), showing == nil, let waiting {
            showing = waiting
            named.insert(waiting)
            self.waiting = nil
        }
        _ = stillness.update(speedMps: speedMps, at: time)
        // Moving again (or not yet still for long enough): the line goes.
        if !stillness.isStill(at: time) { showing = nil }
        let name = district?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        waiting = name.isEmpty || named.contains(name) ? nil : name
    }

    /// The line to show at `now`: the district, while the rider stands; nil while moving.
    public func line(at now: Date) -> String? {
        guard stillness.isStill(at: now) else { return nil }
        return showing ?? waiting
    }
}

public extension WatchJourneyEnd {
    /// The district lines from the summary's districts as plain values: the names
    /// this journey made yours, and those it completed, each once, in the order
    /// given, and nil when there are none.
    static func districtNames(_ names: [String]) -> [String]? {
        var seen: Set<String> = []
        let kept = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return kept.isEmpty ? nil : kept
    }
}
