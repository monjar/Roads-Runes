import Foundation

/// Every tap the Watch gives, named in one place so the game's taps can be kept
/// apart from the turn taps by test. Two clicks mean a turn is coming; one or two
/// direction taps mean turn now. A fight must never say either (docs/ROADMAP.md,
/// 0.6.1): a "staggered" tap that felt like the first half of a left turn is a
/// game reaching into navigation.
public enum WristTap: String, CaseIterable, Hashable, Sendable {
    case click, directionUp, directionDown
    case start, success, failure

    /// The taps navigation owns.
    public static let turns: Set<WristTap> = [.click, .directionUp, .directionDown]
    /// The only taps a fight may use.
    public static let fight: Set<WristTap> = [.start, .success, .failure]
}

/// Something about a fight worth a tap on the wrist, sent from the phone.
public enum FightBeat: String, Codable, CaseIterable, Hashable, Sendable {
    /// It has noticed you.
    case engaged = "ENGAGED"
    /// Left behind loosened.
    case loosened = "LOOSENED"

    public var tap: WristTap {
        switch self {
        case .engaged: return .start
        case .loosened: return .failure
        }
    }
}

/// iPhone → Watch: one fight beat. Unknown to Watch builds before 0.6.1, which
/// drop it (an unknown message kind is ignored).
public struct WatchEncounterBeat: Codable, Hashable, Sendable {
    public var beat: FightBeat
    public var name: String

    public init(beat: FightBeat, name: String) {
        self.beat = beat
        self.name = name
    }
}

/// Whether a fight may make a sound or a tap now: never while a turn is close
/// enough to be cued, so nothing on the wrist or in the ear can be taken for one.
public enum TurnWindow {
    public static func isClear(distanceToInstructionMeters: Double?) -> Bool {
        guard let distance = distanceToInstructionMeters else { return true }
        return distance > TurnCueTracker.approachMeters
    }
}

/// Still enough to read: under 0.7 m/s for five seconds. An unknown speed counts
/// as moving. The ride screen shows words, and the note button, only then.
public struct Stillness: Sendable {
    public static let speedMps = 0.7
    public static let seconds: TimeInterval = 5

    private var stillSince: Date?

    public init() {}

    public mutating func update(speedMps: Double?, at now: Date) -> Bool {
        guard let speed = speedMps, speed >= 0, speed < Self.speedMps else {
            stillSince = nil
            return false
        }
        if stillSince == nil { stillSince = now }
        return now.timeIntervalSince(stillSince!) >= Self.seconds
    }
}
