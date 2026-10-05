import Foundation

/// The words Journey's end uses for what a journey earned and what got away. Kept
/// here, away from the views, so the copy can be tested and the Watch can share it.
public enum RewardCopy {
    /// A line of the XP breakdown, in plain words.
    public static func xp(source: String, className: String? = nil) -> String {
        switch source {
        case "QUEST_COMPLETED": return "Quest"
        case "STORY_QUEST_COMPLETED": return "Story quest"
        case "STORY_ARC_COMPLETED": return "Story arc finished"
        case "QUEST_OBJECTIVE_COMPLETED": return "Objectives"
        case "NEW_AREA_EXPLORED": return "New tiles explored"
        case "NEW_ROAD_EXPLORED": return "New roads"
        case "KNOWN_GROUND": return "Already explored"
        case "DISCOVERY_FOUND": return "Places found"
        case "LONG_DISTANCE_ADVENTURE": return "A long journey"
        case "CLIMB_COMPLETED": return "Climbing"
        case "CHEST_OPENED": return "Chests"
        case "COLLECTABLE_FOUND": return "Pieces"
        case "MONSTER_BEATEN": return "Creatures defeated"
        case "BLOWS_LANDED": return "Creatures weakened"
        case "SET_COMPLETED": return "Set complete"
        case "SOCIAL_QUEST_COMPLETED": return "Party quest"
        case "PATHFINDER": return "Pathfinder bonus"
        case "FAR_WANDERER": return "Far from home"
        case "WELCOME_BACK": return "Welcome-back bonus"
        case "WEEK_NOTICE": return "This week's notice"
        case "REGION_COMPLETED": return "Region complete"
        case "CLASS_BONUS": return className.map { "\($0) bonus" } ?? "Class bonus"
        default: return humanised(source)
        }
    }

    /// A line of the coin breakdown.
    public static func coins(kind: String) -> String {
        switch kind {
        case "RIDE_DISTANCE": return "Distance"
        case "NEW_CELLS": return "New tiles"
        case "QUEST_COMPLETED": return "Quest reward"
        case "CHEST_OPENED": return "Chests"
        case "COLLECTABLE": return "Pieces"
        case "MONSTER_SLAIN": return "Creatures defeated"
        case "BOUNTY": return "Bounty"
        case "STREAK": return "Streak bonus"
        case "SET_COMPLETED": return "Set complete"
        case "STORY_ARC": return "Story arc finished"
        case "WEEK_NOTICE": return "This week's notice"
        case "ITEM_SOLD": return "Sold on the spot"
        case "LEVEL_REWARD": return "Level reward"
        default: return humanised(kind)
        }
    }

    /// "You went 2:18 a kilometre; it needed 2:10." Nil when there is nothing to
    /// measure (a note not written, a shape not drawn).
    public static func nearMiss(_ attempt: MissedAttempt, units: Units = .metric) -> String? {
        switch attempt.method {
        case .pace:
            guard let given = attempt.paceSecPerKm, let wanted = attempt.targetSecPerKm else { return nil }
            let imperial = units == .imperial
            let scale = imperial ? 1.609_344 : 1.0
            return "You went \(pace(given * scale)) a \(imperial ? "mile" : "kilometre"); it needed \(pace(wanted * scale))."
        case .climb:
            guard let gain = attempt.gainMeters, let wanted = attempt.targetGainMeters else { return nil }
            let formatter = UnitFormatter(units: units)
            return "You climbed \(formatter.elevation(meters: gain)) near it; it needed \(formatter.elevation(meters: wanted))."
        case .explore:
            guard let cells = attempt.cells, let wanted = attempt.targetCells else { return nil }
            return "You explored \(cells) new \(cells == 1 ? "tile" : "tiles") near it; it needed \(wanted)."
        default:
            return nil
        }
    }

    /// "It stays two more days." / "It leaves within a day."
    public static func staying(until expiry: Date, now: Date = Date()) -> String {
        let days = Int(expiry.timeIntervalSince(now) / 86_400)
        switch days {
        case ..<1: return expiry > now ? "It leaves within a day." : "It has left."
        case 1: return "It stays one more day."
        default: return "It stays \(spelled(days)) more days."
        }
    }

    /// The whole of a near thing: "The Fen Troll held on. You went … It stays two more days."
    public static func heldOn(_ missed: MissedObject, units: Units = .metric, now: Date = Date()) -> String {
        var parts = ["\(missed.name) held on."]
        if let attempt = missed.attempt, let line = nearMiss(attempt, units: units) { parts.append(line) }
        if let expiry = missed.expiresAt { parts.append(staying(until: expiry, now: now)) }
        return parts.joined(separator: " ")
    }

    /// m:ss, the way a pace is said.
    public static func pace(_ secondsPerUnit: Double) -> String {
        let total = Int(secondsPerUnit.rounded())
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    static func spelled(_ number: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(number) ? words[number] : String(number)
    }

    static func humanised(_ code: String) -> String {
        let words = code.lowercased().split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
