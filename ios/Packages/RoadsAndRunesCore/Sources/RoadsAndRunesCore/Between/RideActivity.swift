import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What the Live Activity and the Dynamic Island show while a journey records
/// (0.7.3): the next turn and how far to it, the distance so far, and the
/// quarry's mark in its ring of health. There are no words about the fight;
/// the mark and the ring say it.
///
/// The state is a plain value so the app, its tests and `swift test` can build
/// it without ActivityKit; `RideActivityAttributes.ContentState` is this type.
public struct RideActivityState: Codable, Hashable, Sendable {
    /// The engine's words for the next turn ("Turn left onto Mill Lane").
    public var instructionText: String?
    /// The turn as an `InstructionSign` raw value ("LEFT"), for the arrow.
    public var maneuver: String?
    public var distanceToTurnMeters: Double?
    /// How far the journey has gone so far.
    public var distanceMeters: Double
    /// The quarry's mark as a `GameIcon` raw name.
    public var quarryIcon: String?
    /// Whole tenths of the quarry's health left, 0…10; nil when nothing is fought.
    public var quarryTenthsLeft: Int?
    public var paused: Bool

    public init(
        instructionText: String? = nil, maneuver: String? = nil, distanceToTurnMeters: Double? = nil,
        distanceMeters: Double = 0, quarryIcon: String? = nil, quarryTenthsLeft: Int? = nil, paused: Bool = false
    ) {
        self.instructionText = instructionText
        self.maneuver = maneuver
        self.distanceToTurnMeters = distanceToTurnMeters
        self.distanceMeters = distanceMeters
        self.quarryIcon = quarryIcon
        self.quarryTenthsLeft = quarryTenthsLeft.map { min(10, max(0, $0)) }
        self.paused = paused
    }

    /// The state from what navigation knows: where it is, the next turn and how
    /// far to it, the distance so far and the fight the Watch is shown.
    public init(
        state: NavigationState, instruction: Instruction?, distanceToTurnMeters: Double?,
        distanceMeters: Double, fight: WatchFight?
    ) {
        // A finish or a bare "carry on" is still worth its words; an unrouted
        // journey has no turn at all.
        let following = state != .paused && instruction != nil
        self.init(
            instructionText: following ? instruction?.text : nil,
            maneuver: following ? instruction?.sign.rawValue : nil,
            distanceToTurnMeters: following ? distanceToTurnMeters.map { max(0, $0) } : nil,
            distanceMeters: max(0, distanceMeters),
            quarryIcon: fight?.icon,
            quarryTenthsLeft: fight?.tenthsLeft,
            paused: state == .paused
        )
    }

    /// The same state the Watch is sent, so the wrist and the lock screen agree.
    public init(update: WatchNavigationUpdate) {
        self.init(
            state: update.state, instruction: update.instruction, distanceToTurnMeters: update.distanceToInstructionMeters,
            distanceMeters: update.distanceMeters, fight: update.fight
        )
    }

    public var sign: InstructionSign? { maneuver.map(InstructionSign.lenient) }

    /// Whether a quarry's mark and ring belong on screen.
    public var showsQuarry: Bool { quarryIcon != nil && quarryTenthsLeft != nil }

    /// The ring's fill, 0…1.
    public var quarryFraction: Double { Double(quarryTenthsLeft ?? 0) / 10 }

    /// Whether the next turn differs from `other`'s: a new arrow is worth an
    /// update at once, a few metres nearer is not.
    public func turnDiffers(from other: RideActivityState) -> Bool {
        maneuver != other.maneuver || instructionText != other.instructionText || paused != other.paused
    }

    /// The SF Symbol for a turn, matching the ride screen's arrow.
    public static func symbol(for sign: InstructionSign?) -> String {
        switch sign {
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.turn.down.left"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.turn.down.right"
        case .uTurn: return "arrow.uturn.left"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .finish: return "flag.checkered"
        case .waypoint: return "mappin"
        case .continue, .unknown, nil: return "arrow.up"
        }
    }

    /// A short phrase for a turn, for VoiceOver and when the engine sent no words.
    public static func phrase(for sign: InstructionSign?) -> String {
        switch sign {
        case .slightLeft: return "Bear left"
        case .left: return "Turn left"
        case .sharpLeft: return "Sharp left"
        case .slightRight: return "Bear right"
        case .right: return "Turn right"
        case .sharpRight: return "Sharp right"
        case .uTurn: return "Turn around"
        case .roundabout: return "At the roundabout"
        case .finish: return "Arrive"
        case .waypoint: return "Waypoint"
        case .continue, .unknown, nil: return "Continue"
        }
    }
}

/// When the app pushes a new state to the Live Activity: at most every few
/// seconds, except at once when the turn changes, the journey pauses or
/// resumes, or the quarry's ring loses a tick.
public struct RideActivityThrottle: Hashable, Sendable {
    public static let interval: TimeInterval = 5

    public private(set) var lastSent: RideActivityState?
    public private(set) var lastSentAt: Date?

    public init() {}

    /// Whether `state` should be sent now; records it as sent when it should.
    public mutating func shouldSend(_ state: RideActivityState, at now: Date = Date()) -> Bool {
        guard wants(state, at: now) else { return false }
        lastSent = state
        lastSentAt = now
        return true
    }

    private func wants(_ state: RideActivityState, at now: Date) -> Bool {
        guard let lastSent, let lastSentAt else { return true }
        if state == lastSent { return false }
        if state.turnDiffers(from: lastSent) || state.quarryTenthsLeft != lastSent.quarryTenthsLeft
            || state.quarryIcon != lastSent.quarryIcon {
            return true
        }
        return now.timeIntervalSince(lastSentAt) >= Self.interval
    }

    public mutating func reset() {
        lastSent = nil
        lastSentAt = nil
    }
}

#if canImport(ActivityKit) && os(iOS)
/// The ride's Live Activity: what does not change during the journey, and the
/// state that does.
public struct RideActivityAttributes: ActivityAttributes, Hashable {
    public typealias ContentState = RideActivityState

    /// `Activity` raw value: RIDE, RUN or WALK.
    public var activity: String
    public var questTitle: String?
    /// `Units` raw value, so the lock screen reads distances as the app does; nil is metric.
    public var units: String?

    public init(activity: String, questTitle: String? = nil, units: String? = nil) {
        self.activity = activity
        self.questTitle = questTitle
        self.units = units
    }

    public var formatter: UnitFormatter {
        UnitFormatter(units: units.map(Units.lenient).flatMap { $0.isUnknown ? nil : $0 } ?? .metric)
    }
}
#endif
