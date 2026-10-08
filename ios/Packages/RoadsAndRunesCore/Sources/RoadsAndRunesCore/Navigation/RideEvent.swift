import Foundation

/// Something that happened on a ride that the rider should hear about without
/// looking: the phone is in a pocket, and nearly everything the ride had to say
/// it said on a screen. One stream of these feeds the chimes, the voice, the
/// Watch and the pills on screen, so a new kind of feedback is one more listener
/// and not another set of calls threaded through the recorder.
public enum RideEvent: Hashable, Sendable {
    /// What lies along the route, said once at the start.
    case briefing(chests: Int, pieces: Int, monsters: [String])
    /// Something has come into sight.
    case sighted(name: String, kind: WorldObjectKind, meters: Double, method: KillMethodKind?)
    case claimed(name: String, kind: WorldObjectKind, coins: Int, set: SetStanding?)
    /// A legend's phase broken (0.8.0): the journey's one, as far as the phone can tell.
    case phaseBroken(name: String)
    /// A creature met and left behind: it escaped.
    case lost(name: String)
    /// Effort is damage (0.6.1): it has noticed you, and what it is weak to.
    case engaged(name: String, wants: [String])
    /// A rune ride or a note struck it: the deliberate blows, worth saying.
    case landed(name: String, kind: String)
    /// Left behind with some of its health taken: weakened, it will remember you.
    case loosened(name: String)
    case objectiveCompleted(title: String, remaining: Int)
    /// The nth new cell in a run of new ground.
    case newGround(run: Int)
    case newPlace(name: String)
    case milestone(RideMilestone, remainingMeters: Double)
    case hillAhead(lengthMeters: Double, gainMeters: Double)
    case hillTop
    case offRoute
    case rerouted
}

public enum RideMilestone: String, Hashable, Sendable {
    case halfway, lastKilometre, arrived
}

/// How much of the ride is said aloud. Chimes are the default: a voice is asked for.
public enum RideSound: String, CaseIterable, Hashable, Sendable {
    case off, chimes, voice

    public var title: String {
        switch self {
        case .off: return "Off"
        case .chimes: return "Chimes"
        case .voice: return "Chimes and voice"
        }
    }
}

extension RideEvent {
    public var chime: RideChime? {
        switch self {
        case .briefing: return nil
        case .sighted: return .sighted
        case .claimed(_, let kind, _, let set):
            if set?.isComplete == true { return .questDone }
            switch kind {
            case .monster: return .win
            case .chest: return .chest
            default: return .piece
            }
        case .phaseBroken: return .win
        case .lost, .loosened: return .lost
        case .engaged: return .engaged
        case .landed: return .landed
        case .objectiveCompleted(_, let remaining): return remaining == 0 ? .questDone : .objective
        case .newGround: return .newGround
        case .newPlace: return .place
        case .milestone(let which, _): return which == .arrived ? .arrived : .milestone
        case .hillAhead: return .hill
        case .hillTop: return .milestone
        case .offRoute: return .offRoute
        case .rerouted: return .rerouted
        }
    }

    /// Which note of the scale a chime plays, for the ones that climb.
    public var chimeStep: Int {
        if case .newGround(let run) = self { return max(0, run - 1) }
        return 0
    }

    /// The line said aloud, short enough to take in on a bike. Nil for what a chime says well enough.
    public func spoken(units: Units = .metric) -> String? {
        let formatter = UnitFormatter(units: units)
        switch self {
        case .briefing:
            return pill(units: units).map { "\($0)." }
        case .sighted(let name, let kind, let meters, _):
            let distance = Self.spokenDistance(meters, units: units)
            switch kind {
            case .monster:
                // Five words at most: what it is weak to is said when it notices you.
                return "\(name), \(distance)."
            case .chest: return "A chest, \(distance)."
            default: return "A piece, \(distance)."
            }
        case .claimed(let name, let kind, let coins, let set):
            switch kind {
            case .monster: return "\(name) defeated! \(coins) coins."
            case .chest: return "Chest opened. \(coins) coins."
            default:
                if let set { return "\(name). \(set.line)." }
                return "\(name). \(coins) coins."
            }
        case .phaseBroken:
            return LegendCopy.phaseBroken
        case .lost(let name):
            return "\(name) escaped."
        case .engaged(let name, let wants):
            // "Fen Troll. Weak to climbing." Five words, name first.
            guard let first = wants.first else { return "\(name)." }
            return "\(name). Weak to \(LoreCopy.kind(first))."
        case .landed(_, let kind):
            return kind == "RUNE" ? "Rune strike." : "Note strike."
        case .loosened(let name):
            return "\(name) weakened."
        case .objectiveCompleted(_, let remaining):
            if remaining == 0 { return "Quest complete! Head home." }
            return "Objective done. \(RewardCopy.spelled(remaining).capitalized) left."
        case .newGround:
            return nil
        case .newPlace(let name):
            return "New place: \(name)."
        case .milestone(let which, _):
            switch which {
            case .halfway: return "Halfway."
            case .lastKilometre: return units == .imperial ? "Under a mile to go." : "One kilometre to go."
            case .arrived: return "You've arrived."
            }
        case .hillAhead(let length, _):
            return "A hill ahead: \(formatter.distance(meters: (length / 100).rounded() * 100))."
        case .hillTop:
            return "Top of the hill."
        case .offRoute:
            return nil
        case .rerouted:
            return "New route."
        }
    }

    /// A line for the screen, for the events that otherwise show nothing there.
    public func pill(units: Units = .metric) -> String? {
        let formatter = UnitFormatter(units: units)
        switch self {
        case .briefing(let chests, let pieces, let monsters):
            var parts: [String] = []
            if chests > 0 { parts.append("\(RewardCopy.spelled(chests)) \(chests == 1 ? "chest" : "chests")") }
            if pieces > 0 { parts.append("\(RewardCopy.spelled(pieces)) \(pieces == 1 ? "piece" : "pieces")") }
            parts.append(contentsOf: monsters.prefix(2).map { "the \($0)" })
            if monsters.count > 2 { parts.append("\(RewardCopy.spelled(monsters.count - 2)) more") }
            guard !parts.isEmpty else { return nil }
            let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
            return (list.prefix(1).uppercased() + list.dropFirst()) + " on this route"
        case .newPlace(let name):
            return "New place: \(name)"
        case .milestone(let which, let remaining):
            switch which {
            case .halfway: return "Halfway · \(formatter.distance(meters: remaining)) to go"
            case .lastKilometre: return "\(formatter.distance(meters: remaining)) to go"
            case .arrived: return "You've arrived"
            }
        case .hillAhead(let length, let gain):
            return "A hill ahead · \(formatter.distance(meters: length)) · \(formatter.elevation(meters: gain)) up"
        case .hillTop:
            return "Top of the hill"
        case .lost(let name):
            return "\(name) escaped"
        case .phaseBroken(let name):
            return "\(LegendCopy.phaseBroken) \(name)"
        default:
            return nil
        }
    }

    /// Which line goes first when several are waiting. A win outranks a sighting; a
    /// milestone can wait for either.
    public var priority: Int {
        switch self {
        case .claimed, .objectiveCompleted, .phaseBroken: return 5
        case .sighted, .lost: return 4
        // A fight never outranks being off the route.
        case .engaged, .landed, .loosened: return 3
        case .rerouted, .offRoute: return 4
        case .hillAhead, .newPlace: return 3
        case .milestone, .hillTop: return 2
        case .briefing: return 2
        case .newGround: return 1
        }
    }

    /// Seconds a line may wait its turn before it is no longer true enough to say.
    public var shelfLife: TimeInterval {
        switch self {
        case .sighted, .hillAhead: return 12
        case .newPlace, .hillTop, .lost, .rerouted, .offRoute, .landed, .loosened: return 20
        case .engaged: return 12
        case .milestone(let which, _): return which == .arrived ? 60 : 30
        case .briefing: return 45
        case .claimed, .objectiveCompleted, .phaseBroken: return 60
        case .newGround: return 5
        }
    }

    /// A distance for the ear: to the nearest fifty metres, or as the formatter says it.
    static func spokenDistance(_ meters: Double, units: Units) -> String {
        guard units != .imperial else { return UnitFormatter(units: units).distance(meters: meters) }
        let rounded = max(50, Int((meters / 50).rounded()) * 50)
        return "\(rounded) metres"
    }

    /// What of the world lies along a route: anything within `within` metres of its line.
    public static func briefing(for objects: [WorldObject], along path: [Coordinate], within: Double = 150) -> RideEvent {
        guard path.count >= 2 else { return .briefing(chests: 0, pieces: 0, monsters: []) }
        let onTheWay = objects.filter { object in
            object.status == .spawned && zip(path, path.dropFirst()).contains {
                GeoMath.distance(from: object.coordinate, toSegment: $0, $1) <= within
            }
        }
        return .briefing(
            chests: onTheWay.filter { $0.kind == .chest }.count,
            pieces: onTheWay.filter { $0.kind == .collectable }.count,
            monsters: onTheWay.filter { $0.kind == .monster }.map(\.name)
        )
    }
}

// MARK: - Chimes

/// The sounds a ride makes. They are described as notes, not files: a short bell
/// can be made from a sine and a decay, and a scale can climb as far as the ride does.
public enum RideChime: String, CaseIterable, Hashable, Sendable {
    case sighted, chest, piece, win, lost, objective, questDone, place, milestone, arrived, hill, offRoute, rerouted, newGround
    /// It has noticed you: knock, knock, a call.
    case engaged
    /// A rune or the word landed: a low strike and a ring.
    case landed

    public struct Note: Hashable, Sendable {
        public var frequency: Double
        public var start: Double
        public var duration: Double
        public var gain: Double

        public init(_ frequency: Double, at start: Double = 0, for duration: Double = 0.35, gain: Double = 0.5) {
            self.frequency = frequency
            self.start = start
            self.duration = duration
            self.gain = gain
        }
    }

    /// A major pentatonic from C5, two octaves: every step sounds like going up.
    public static let scale: [Double] = [523.25, 587.33, 659.25, 783.99, 880.00, 1046.50, 1174.66, 1318.51, 1567.98, 1760.00]

    /// The notes of the chime. `step` is which degree of the scale `newGround` plays.
    public func notes(step: Int = 0) -> [Note] {
        switch self {
        case .sighted: return [Note(392.00, for: 0.22, gain: 0.35), Note(523.25, at: 0.13, for: 0.3, gain: 0.35)]
        case .chest: return [Note(196.00, for: 0.09, gain: 0.6), Note(196.00, at: 0.14, for: 0.09, gain: 0.6), Note(1318.51, at: 0.30, for: 0.5, gain: 0.4)]
        case .piece: return [Note(1318.51, for: 0.25, gain: 0.4), Note(1567.98, at: 0.09, for: 0.45, gain: 0.4)]
        case .win: return [Note(523.25, for: 0.2), Note(659.25, at: 0.12, for: 0.2), Note(783.99, at: 0.24, for: 0.2), Note(1046.50, at: 0.36, for: 0.7)]
        case .lost: return [Note(329.63, for: 0.25, gain: 0.4), Note(261.63, at: 0.2, for: 0.5, gain: 0.4)]
        case .objective: return [Note(523.25, for: 0.2), Note(783.99, at: 0.14, for: 0.5)]
        case .questDone: return [Note(523.25, for: 0.25), Note(659.25, at: 0.18, for: 0.25), Note(783.99, at: 0.36, for: 0.25), Note(1046.50, at: 0.54, for: 0.3), Note(1318.51, at: 0.72, for: 0.9)]
        case .place: return [Note(880.00, for: 0.8, gain: 0.4)]
        case .milestone: return [Note(783.99, for: 0.18, gain: 0.4), Note(783.99, at: 0.2, for: 0.4, gain: 0.4)]
        case .arrived: return [Note(392.00, for: 0.2), Note(523.25, at: 0.14, for: 0.2), Note(659.25, at: 0.28, for: 0.2), Note(783.99, at: 0.42, for: 0.2), Note(1046.50, at: 0.56, for: 1.0)]
        case .hill: return [Note(261.63, for: 0.25, gain: 0.45), Note(329.63, at: 0.18, for: 0.45, gain: 0.45)]
        case .offRoute: return [Note(220.00, for: 0.28, gain: 0.5), Note(220.00, at: 0.36, for: 0.28, gain: 0.5)]
        case .rerouted: return [Note(659.25, for: 0.2, gain: 0.4), Note(880.00, at: 0.14, for: 0.45, gain: 0.4)]
        case .newGround: return [Note(Self.scale[min(max(0, step), Self.scale.count - 1)], for: 0.45, gain: 0.3)]
        case .engaged: return [Note(293.66, for: 0.12, gain: 0.5), Note(293.66, at: 0.18, for: 0.12, gain: 0.5), Note(440.00, at: 0.40, for: 0.45, gain: 0.45)]
        case .landed: return [Note(220.00, for: 0.3, gain: 0.5), Note(329.63, for: 0.3, gain: 0.35), Note(440.00, at: 0.22, for: 0.6, gain: 0.45)]
        }
    }

    public func length(step: Int = 0) -> Double {
        notes(step: step).map { $0.start + $0.duration }.max() ?? 0
    }
}

// MARK: - What gets said, and when

/// Spaces the spoken lines out. A chime is short and plays at once; a voice that
/// said every line as it came would talk over itself and over the road, so lines
/// wait their turn, the weightier first, and one that has waited too long to be
/// true is dropped rather than said late.
public struct RideAnnouncer: Sendable {
    public var minimumGap: TimeInterval

    private struct Pending: Sendable {
        var event: RideEvent
        var line: String
        var offeredAt: Date
    }

    private var queue: [Pending] = []
    private var lastSpokenAt: Date?

    public init(minimumGap: TimeInterval = 4) {
        self.minimumGap = minimumGap
    }

    public var waiting: Int { queue.count }

    public mutating func offer(_ event: RideEvent, units: Units = .metric, at now: Date) {
        guard let line = event.spoken(units: units) else { return }
        // A newer sighting replaces an older one still waiting: only the nearest thing is news.
        if case .sighted = event {
            queue.removeAll { if case .sighted = $0.event { return true } else { return false } }
        }
        queue.append(Pending(event: event, line: line, offeredAt: now))
    }

    /// The next line to say, if it is time to say one.
    public mutating func nextLine(now: Date, isSpeaking: Bool = false) -> String? {
        queue.removeAll { now.timeIntervalSince($0.offeredAt) > $0.event.shelfLife }
        guard !isSpeaking, !queue.isEmpty else { return nil }
        if let last = lastSpokenAt, now.timeIntervalSince(last) < minimumGap { return nil }
        let index = queue.indices.max { a, b in
            (queue[a].event.priority, queue[b].offeredAt) < (queue[b].event.priority, queue[a].offeredAt)
        }!
        let pending = queue.remove(at: index)
        lastSpokenAt = now
        return pending.line
    }

    /// Speech has finished: the gap is measured from the end of a line, not its start.
    public mutating func finishedSpeaking(at now: Date) {
        lastSpokenAt = now
    }
}

// MARK: - Milestones and hills

/// Turns route progress into the few moments worth marking: halfway, the last
/// kilometre, arriving, a hill coming and its top. Each is said once.
public struct RideMilestones: Sendable {
    public static let minimumRouteMeters = 2000.0
    public static let minimumHillGainMeters = 15.0
    public static let hillWarningMeters = 200.0

    private var totalMeters: Double
    private var climbs: [Climb]
    private var fired: Set<RideMilestone> = []
    private var hillsAnnounced: Set<Int> = []
    private var hillsTopped: Set<Int> = []

    public init(totalMeters: Double, climbs: [Climb]) {
        self.totalMeters = totalMeters
        self.climbs = climbs
    }

    public init(route: RouteOption) {
        self.init(totalMeters: route.distanceMeters, climbs: route.climbs)
    }

    /// A reroute is a new line with its own hills; what has already been said stays said.
    public mutating func retarget(route: RouteOption) {
        totalMeters = route.distanceMeters
        climbs = route.climbs
        hillsAnnounced = []
        hillsTopped = []
    }

    public mutating func update(progress: ProgressUpdate) -> [RideEvent] {
        guard !progress.isOffRoute, totalMeters > 0 else { return [] }
        var events: [RideEvent] = []
        let along = progress.distanceAlongRoute
        let remaining = progress.distanceRemaining

        for (index, climb) in climbs.enumerated() where climb.gainMeters >= Self.minimumHillGainMeters {
            let top = climb.startMeters + climb.lengthMeters
            if !hillsAnnounced.contains(index), along >= climb.startMeters - Self.hillWarningMeters, along < climb.startMeters + climb.lengthMeters * 0.25 {
                hillsAnnounced.insert(index)
                events.append(.hillAhead(lengthMeters: climb.lengthMeters, gainMeters: climb.gainMeters))
            } else if hillsAnnounced.contains(index), !hillsTopped.contains(index), along >= top {
                hillsTopped.insert(index)
                events.append(.hillTop)
            }
        }

        guard totalMeters >= Self.minimumRouteMeters else { return events }
        if !fired.contains(.halfway), progress.fractionComplete >= 0.5, progress.fractionComplete < 0.9 {
            fired.insert(.halfway)
            events.append(.milestone(.halfway, remainingMeters: remaining))
        }
        if !fired.contains(.lastKilometre), totalMeters >= 3000, remaining <= 1000, remaining > 150 {
            fired.insert(.lastKilometre)
            events.append(.milestone(.lastKilometre, remainingMeters: remaining))
        }
        // A loop ends where it starts: "arrived" needs most of it ridden, not only the place.
        if !fired.contains(.arrived), remaining <= 40, along >= totalMeters * 0.9 {
            fired.insert(.arrived)
            events.append(.milestone(.arrived, remainingMeters: remaining))
        }
        return events
    }
}

/// Counts a run of new ground: each new cell is one more, until the ride has been
/// on known roads long enough for the next to be the start of another run.
public struct NewGroundRun: Sendable {
    public static let resetAfterSeconds: TimeInterval = 120

    public private(set) var run = 0
    private var lastAt: Date?

    public init() {}

    public mutating func entered(at now: Date) -> Int {
        if let lastAt, now.timeIntervalSince(lastAt) > Self.resetAfterSeconds { run = 0 }
        run += 1
        lastAt = now
        return run
    }
}
