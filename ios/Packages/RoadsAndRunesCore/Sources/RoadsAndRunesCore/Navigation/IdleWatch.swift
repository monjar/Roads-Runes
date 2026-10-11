import Foundation

/// A journey left standing (0.9.2): a ride never ended, or a long stop. Twenty
/// minutes without moving 50 m, the GPS drops to Endurance and the phone and the
/// Watch ask "Still out? End ride or keep going."; again at an hour. A journey with
/// no route (Ride anywhere) that has stood two hours ends itself, trimmed to the
/// last time it moved. Moving again puts everything back.
///
/// Pure and timer-driven: fixes say where the rider is (`moved`), a clock says what
/// time it is (`tick`); it keeps no clock of its own. Fixes stop when the rider does,
/// so the clock is what notices.
public struct IdleWatch: Hashable, Sendable {
    /// Moving is getting this far from where the rider stopped; GPS drifts less.
    public static let movedMeters = 50.0
    /// When it asks, in minutes still.
    public static let askAtMinutes = [20, 60]
    /// When a journey with no route ends itself.
    public static let endAfterSeconds: TimeInterval = 2 * 60 * 60

    public enum Action: Hashable, Sendable {
        /// Drop the GPS to Endurance until the rider moves.
        case saveBattery
        /// "Still out? End ride or keep going." after this many minutes still.
        case ask(minutes: Int)
        /// End the journey as it stood when it last moved.
        case end(lastMovedAt: Date)
        /// Moving again: the GPS back as it was, and the question gone.
        case moving
    }

    /// A journey with no route ends itself; a planned one only asks.
    public let endsItself: Bool
    /// Where the rider stopped, and when they last moved.
    public private(set) var anchor: Coordinate?
    public private(set) var lastMovedAt: Date?
    /// The question standing on screen, if any.
    public private(set) var asking = false
    public private(set) var savingBattery = false
    private var asked: Set<Int> = []
    private var ended = false

    public init(endsItself: Bool, startedAt: Date? = nil, at start: Coordinate? = nil) {
        self.endsItself = endsItself
        self.lastMovedAt = startedAt
        self.anchor = start
    }

    /// A fix. Returns `.moving` when it woke the journey from standing.
    public mutating func moved(to position: Coordinate, at time: Date) -> Action? {
        guard let anchor else {
            self.anchor = position
            lastMovedAt = lastMovedAt ?? time
            return nil
        }
        guard GeoMath.distance(anchor, position) > Self.movedMeters else { return nil }
        self.anchor = position
        lastMovedAt = time
        let woke = asking || savingBattery
        asked = []
        asking = false
        savingBattery = false
        return woke ? .moving : nil
    }

    /// The clock, every minute or so: what to do at `now`. Nothing while paused, which
    /// is the rider's own stop.
    public mutating func tick(at now: Date, paused: Bool = false) -> [Action] {
        guard !paused, !ended, let lastMovedAt else { return [] }
        let still = now.timeIntervalSince(lastMovedAt)
        if endsItself, still >= Self.endAfterSeconds {
            ended = true
            asking = false
            return [.end(lastMovedAt: lastMovedAt)]
        }
        var actions: [Action] = []
        for minutes in Self.askAtMinutes where still >= Double(minutes) * 60 && asked.insert(minutes).inserted {
            if !savingBattery {
                savingBattery = true
                actions.append(.saveBattery)
            }
            asking = true
            actions.append(.ask(minutes: minutes))
        }
        // Two thresholds passed at once (a phone asleep): one question.
        if actions.filter({ if case .ask = $0 { return true } else { return false } }).count > 1 {
            actions = actions.filter { if case .ask(let minutes) = $0 { return minutes == asked.max() } else { return true } }
        }
        return actions
    }

    /// "Keep going": the question goes; the next comes at the next threshold.
    public mutating func keepGoing() {
        asking = false
    }

    /// The rider paused or resumed by hand: standing starts again from `now`.
    public mutating func restart(at now: Date, at position: Coordinate? = nil) {
        lastMovedAt = now
        if let position { anchor = position }
        asked = []
        asking = false
        savingBattery = false
    }
}
