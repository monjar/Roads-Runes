import Foundation

/// The words the reckoning uses for what a ride earned and what got away. Kept
/// here, away from the views, so the copy can be tested and the Watch can share it.
public enum RewardCopy {
    /// A line of the XP breakdown, in plain words.
    public static func xp(source: String, className: String? = nil) -> String {
        switch source {
        case "QUEST_COMPLETED": return "The quest"
        case "STORY_QUEST_COMPLETED": return "A step of the story"
        case "STORY_ARC_COMPLETED": return "An arc finished"
        case "QUEST_OBJECTIVE_COMPLETED": return "Objectives"
        case "NEW_AREA_EXPLORED": return "New ground"
        case "NEW_ROAD_EXPLORED": return "New roads"
        case "KNOWN_GROUND": return "Known ground"
        case "DISCOVERY_FOUND": return "Places found"
        case "LONG_DISTANCE_ADVENTURE": return "A long way"
        case "CLIMB_COMPLETED": return "The climbing"
        case "CHEST_OPENED": return "Chests"
        case "COLLECTABLE_FOUND": return "Pieces"
        case "MONSTER_BEATEN": return "Monsters"
        case "SET_COMPLETED": return "A set complete"
        case "SOCIAL_QUEST_COMPLETED": return "Ridden together"
        case "REGION_COMPLETED": return "A region complete"
        case "CLASS_BONUS": return className.map { "\($0) bonus" } ?? "Class bonus"
        default: return humanised(source)
        }
    }

    /// A line of the coin breakdown.
    public static func coins(kind: String) -> String {
        switch kind {
        case "RIDE_DISTANCE": return "The distance"
        case "NEW_CELLS": return "New ground"
        case "QUEST_COMPLETED": return "The quest's purse"
        case "CHEST_OPENED": return "Chests"
        case "COLLECTABLE": return "Pieces"
        case "MONSTER_SLAIN": return "Monsters"
        case "BOUNTY": return "The bounty"
        case "STREAK": return "Days kept"
        case "SET_COMPLETED": return "A set complete"
        case "STORY_ARC": return "An arc finished"
        default: return humanised(kind)
        }
    }

    /// "You gave it 2:18 a kilometre; it wanted 2:10." Nil when there is nothing to
    /// measure (a note not written, a shape not drawn).
    public static func nearMiss(_ attempt: MissedAttempt, units: Units = .metric) -> String? {
        switch attempt.method {
        case .pace:
            guard let given = attempt.paceSecPerKm, let wanted = attempt.targetSecPerKm else { return nil }
            let imperial = units == .imperial
            let scale = imperial ? 1.609_344 : 1.0
            return "You gave it \(pace(given * scale)) a \(imperial ? "mile" : "kilometre"); it wanted \(pace(wanted * scale))."
        case .climb:
            guard let gain = attempt.gainMeters, let wanted = attempt.targetGainMeters else { return nil }
            let formatter = UnitFormatter(units: units)
            return "You climbed \(formatter.elevation(meters: gain)) beside it; it wanted \(formatter.elevation(meters: wanted))."
        case .explore:
            guard let cells = attempt.cells, let wanted = attempt.targetCells else { return nil }
            return "You cleared \(cells) new \(cells == 1 ? "area" : "areas") round it; it wanted \(wanted)."
        default:
            return nil
        }
    }

    /// "It is there two more days." / "It is gone tonight."
    public static func staying(until expiry: Date, now: Date = Date()) -> String {
        let days = Int(expiry.timeIntervalSince(now) / 86_400)
        switch days {
        case ..<1: return expiry > now ? "It is gone tonight." : "It has gone."
        case 1: return "It is there one more day."
        default: return "It is there \(spelled(days)) more days."
        }
    }

    /// The whole of a near thing: "The Fen Troll shrugged it off. You gave it … It is there two more days."
    public static func shruggedOff(_ missed: MissedObject, units: Units = .metric, now: Date = Date()) -> String {
        var parts = ["\(missed.name) shrugged it off."]
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
