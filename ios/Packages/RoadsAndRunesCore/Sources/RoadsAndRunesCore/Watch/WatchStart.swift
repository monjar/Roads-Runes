import Foundation

// Starting a journey from the wrist (0.7.3). The Watch asks; the phone plans it
// (a loop, the bounty, a quest or a sealed quest) and starts the ride itself, so
// the Watch still never runs its own GPS. The route summary that every ride
// sends is the Watch's answer that it worked; `WatchStartResult` says when it
// did not. A phone from before 0.7.3 cannot name the kind and drops the request,
// and the Watch gives up waiting (`RideStore.planningTimeout`).

/// Watch → iPhone: plan this and start it.
public struct WatchStartRequest: Codable, Hashable, Identifiable, Sendable {
    public static let loop = "LOOP"
    public static let bounty = "BOUNTY"
    public static let quest = "QUEST"
    public static let sealed = "SEALED"

    /// A request heard later than this is let go: nobody wants a ride to start
    /// itself minutes after they asked for it.
    public static let keptFor: TimeInterval = 120

    /// So the phone's answer can be matched to the question.
    public var id: UUID
    /// LOOP, BOUNTY, QUEST or SEALED; a string, so a kind added later reaches an
    /// older phone as one it refuses rather than an error.
    public var kind: String
    /// How long a loop or a sealed quest should last.
    public var minutes: Int?
    /// The quest to start (QUEST).
    public var questId: UUID?
    /// RIDE, RUN or WALK; the phone's own choice when nil.
    public var activity: String?
    public var requestedAt: Date?

    public init(id: UUID = UUID(), kind: String, minutes: Int? = nil, questId: UUID? = nil, activity: String? = nil,
                requestedAt: Date? = Date()) {
        self.id = id
        self.kind = kind
        self.minutes = minutes
        self.questId = questId
        self.activity = activity
        self.requestedAt = requestedAt
    }

    public static func loop(minutes: Int, activity: Activity?) -> WatchStartRequest {
        WatchStartRequest(kind: loop, minutes: minutes, activity: activity.flatMap { $0 == .unknown ? nil : $0.rawValue })
    }

    public static func bounty(activity: Activity?) -> WatchStartRequest {
        WatchStartRequest(kind: bounty, activity: activity.flatMap { $0 == .unknown ? nil : $0.rawValue })
    }

    public static func quest(id: UUID) -> WatchStartRequest {
        WatchStartRequest(kind: quest, questId: id)
    }

    public static func sealed(minutes: Int) -> WatchStartRequest {
        WatchStartRequest(kind: sealed, minutes: minutes)
    }

    /// Whether the phone should still act on it at `now`. A request with no time
    /// is taken as fresh: it can only have come straight from the wrist.
    public func isFresh(at now: Date = Date()) -> Bool {
        guard let requestedAt else { return true }
        return now.timeIntervalSince(requestedAt) <= Self.keptFor
    }

    /// What the phone's quick start makes of it: nil for a kind it does not know,
    /// a quest with no id, or a request heard too late. A loop without minutes
    /// lasts 40; a loop's activity is the one asked for, else `defaultActivity`.
    public func quickStart(defaultActivity: Activity, at now: Date = Date()) -> QuickStart? {
        guard isFresh(at: now) else { return nil }
        switch kind.uppercased() {
        case Self.loop:
            let asked = activity.map(Activity.lenient)
            let chosen = asked.flatMap { $0.isUnknown ? nil : $0 } ?? (defaultActivity.isUnknown ? .ride : defaultActivity)
            return .loop(minutes: max(5, minutes ?? 40), activity: chosen)
        case Self.bounty:
            return .bounty
        case Self.quest:
            return questId.map { .quest(id: $0) }
        case Self.sealed:
            return .sealed(minutes: QuickStart.sealedMinutes(nearest: minutes ?? 40))
        default:
            return nil
        }
    }
}

/// iPhone → Watch: what came of a start request. Sent when it could not be
/// planned; sent too when the ride started, though the route summary that
/// follows is what takes the Watch to the ride.
public struct WatchStartResult: Codable, Hashable, Sendable {
    public var requestId: UUID?
    public var started: Bool

    public init(requestId: UUID?, started: Bool) {
        self.requestId = requestId
        self.started = started
    }
}
