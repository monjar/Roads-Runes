import Foundation

// Legends on the wrist (0.8.0): "Phase broken!" in the overlay, and the legend,
// the lair and buried treasure on Journey's end. Everything here travels in
// fields an older Watch ignores (`WatchObjectiveCompleted.outcome` is a string
// it reads as a heading; `WatchJourneyEnd`'s new fields are optional).

/// A line of Journey's end with its mark: the legend's, the lair's, the buried treasure's.
public struct WatchEndLine: Codable, Hashable, Sendable {
    public var text: String
    /// Its mark as a `GameIcon` raw name; the Watch falls back to one it has.
    public var icon: String?
    /// A smaller second line: "+120 coins", the lair's name.
    public var detail: String?

    public init(text: String, icon: String? = nil, detail: String? = nil) {
        self.text = text
        self.icon = icon
        self.detail = detail
    }

    /// The legend fought on the journey: the server's own line ("Phase broken! The
    /// Fog Dragon is down to its last phase."), else one made from what happened.
    /// Nil when it was not touched and there is nothing to say.
    public static func legend(name: String, icon: String?, line: String?, damage: Int, phaseBroken: Bool, defeated: Bool) -> WatchEndLine? {
        if let line = line?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            return WatchEndLine(text: line, icon: icon)
        }
        if defeated { return WatchEndLine(text: "\(name) is defeated!", icon: icon) }
        if phaseBroken { return WatchEndLine(text: "Phase broken!", icon: icon, detail: name) }
        guard damage >= 1 else { return nil }
        return WatchEndLine(text: "\(name) took \(damage) damage", icon: icon)
    }

    /// The lair: its great chest once five of its tiles are visited, else how many are.
    public static func lair(name: String?, visited: Int, need: Int, done: Bool) -> WatchEndLine {
        if done { return WatchEndLine(text: "Great chest opened", icon: "greatChest", detail: name) }
        return WatchEndLine(text: "Lair: \(min(visited, need)) of \(need) tiles", icon: "lair", detail: name)
    }

    /// Buried treasure dug up on the way, and the coins it held.
    public static func treasure(count: Int = 1, coins: Int?) -> WatchEndLine {
        let text = count >= 2 ? "\(count) buried treasures found" : "Buried treasure found"
        return WatchEndLine(text: text, icon: "openChest", detail: coins.flatMap { $0 >= 1 ? LoreCopy.earned($0) : nil })
    }
}

public extension WatchObjectiveCompleted {
    /// The overlay's wire words. An older Watch shows any it does not know as written.
    enum Outcome {
        /// A creature defeated; the Watch reads it DEFEATED.
        public static let gone = "GONE"
        public static let opened = "OPENED"
        public static let found = "FOUND"
        public static let done = "DONE"
        /// A legend's phase broken (0.8.0): "Phase broken!"
        public static let phase = "PHASE"
    }

    /// A legend's phase broken: its mark, its name, and how many phases are left.
    /// The phone sends it once, when its fold sees the phase off (`Legend.foe`).
    static func phaseBroken(name: String, icon: String?, broken: Int, of phases: Int) -> WatchObjectiveCompleted {
        let left = max(0, phases - broken)
        let detail: String
        switch left {
        case 0: detail = "Defeated!"
        case 1: detail = "One phase left"
        default: detail = "\(left) phases left"
        }
        return WatchObjectiveCompleted(title: name, detail: detail, outcome: Outcome.phase, icon: icon)
    }

    /// The same, for the legend as the journey fights it (`Legend.foe`): the phase it was on is the one broken.
    static func phaseBroken(_ foe: WorldObject, icon: String?) -> WatchObjectiveCompleted? {
        guard let phases = foe.monster?.phases else { return nil }
        return phaseBroken(name: foe.name, icon: icon, broken: foe.monster?.phase ?? phases, of: phases)
    }

    var isPhaseBroken: Bool { outcome == Outcome.phase }

    /// The one tap the overlay gives: the game's success, never a turn's.
    var tap: WristTap { .success }
}
