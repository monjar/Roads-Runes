import Foundation

/// The app's words for its things (docs/VOICE.md, the glossary), in one place so
/// the phone and the Watch say them the same way and a rename is one edit.
public enum LoreCopy {
    /// Coins, never "AC": "60 coins", "1 coin".
    public static func purse(_ amount: Int) -> String {
        "\(amount.formatted()) \(amount == 1 ? "coin" : "coins")"
    }

    /// "+60 coins", for a claim or a line of Journey's end.
    public static func earned(_ amount: Int) -> String {
        "+\(purse(amount))"
    }

    /// Days in a row are a streak: "1-day streak", "6-day streak".
    public static func streak(_ days: Int) -> String {
        "\(days)-day streak"
    }

    /// An unspent point: "1 skill point to spend", "2 skill points to spend".
    public static func skillPointsToSpend(_ count: Int) -> String {
        "\(count) skill \(count == 1 ? "point" : "points") to spend"
    }

    /// What a level-up brings: "New skill: Trail Sense".
    public static func newSkill(_ name: String) -> String {
        "New skill: \(name)"
    }

    /// The button that makes a character: "Become an Explorer".
    public static func become(_ className: String) -> String {
        let article = "AEIOU".contains(className.prefix(1)) ? "an" : "a"
        return "Become \(article) \(className)"
    }

    /// "Explorer level 8": a class level always says whose level it is.
    public static func classLevel(_ className: String, _ level: Int) -> String {
        "\(className) level \(level)"
    }

    /// "ride", "run" or "walk" when it is known; "journey" when it could be any.
    public static func journey(_ activity: Activity?) -> String {
        guard let activity, activity != .unknown else { return "journey" }
        return activity.noun
    }

    /// "Free ride", "Free run", "Free walk"; "Free journey" when it could be any.
    public static func free(_ activity: Activity?) -> String {
        "Free \(journey(activity))"
    }

    /// "Riding", "Running", "Walking": what the rider is doing now.
    public static func going(_ activity: Activity?) -> String {
        switch activity {
        case .run: return "Running"
        case .walk: return "Walking"
        default: return "Riding"
        }
    }

    /// "ridden", "run", "walked": for "km ridden".
    public static func travelled(_ activity: Activity?) -> String {
        switch activity {
        case .run: return "run"
        case .walk: return "walked"
        default: return "ridden"
        }
    }

    public static let loading = "Unrolling the map…"
    public static let journeysEnd = "Journey's end"
    public static let done = "Done"
    public static let changeClass = "Change class"
}

public extension LoreCopy {
    /// The five kinds of effort, as the glossary says them.
    static func kind(_ kind: String) -> String {
        switch kind.uppercased() {
        case "ROAD": return "distance"
        case "GROUND": return "exploring"
        case "CLIMB": return "climbing"
        case "RUNE": return "rune shape"
        case "WORD": return "a note"
        default: return kind.lowercased()
        }
    }

    /// A way in, said the same way as a kind of effort: "climbing", "a note".
    static func effort(_ method: KillMethodKind) -> String {
        switch method {
        case .pace: return "distance"
        case .climb: return "climbing"
        case .explore: return "exploring"
        case .rune: return "rune shape"
        case .lore: return "a note"
        case .unknown: return "effort"
        }
    }

    /// A rune's shape: "a loop", "a square", "a note".
    static func roadForm(_ form: String?) -> String? {
        switch form?.uppercased() {
        case "LOOP": return "a loop"
        case "TRIANGLE": return "a triangle"
        case "SQUARE": return "a square"
        case "ZIGZAG": return "a zigzag"
        case "NOTE": return "a note"
        case "STOP": return "a stop"
        default: return nil
        }
    }

    /// What to do to make a rune's shape: "Ride a square", "Write a note".
    static func shapeAction(_ form: String?) -> String? {
        switch form?.uppercased() {
        case "LOOP", "TRIANGLE", "SQUARE": return roadForm(form).map { "Ride \($0)" }
        case "ZIGZAG": return "Run or walk a zigzag"
        case "NOTE": return "Write a note"
        case "STOP": return "Stop for a while"
        default: return nil
        }
    }

    /// "Rune: Dagaz. Ride a square near it." or, with no shape known, "Rune: Dagaz."
    static func runeHow(_ rune: String, form: String?) -> String {
        guard let action = shapeAction(form) else { return "Rune: \(rune)." }
        return "Rune: \(rune). \(action) near it."
    }

    /// "Weak to: distance and rune shape".
    static func weakTo(_ kinds: [String]) -> String {
        "Weak to: \(list(kinds.map(kind)))"
    }

    /// "Resists: climbing".
    static func resists(_ kinds: [String]) -> String {
        "Resists: \(list(kinds.map(kind)))"
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ words: [String]) -> String {
        guard let last = words.last else { return "" }
        return words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The five who write the board, by cast id (backend lore/config/cast.json).
    static func castName(_ id: String?) -> String? {
        switch id {
        case "ada-pym": return "Ada Pym"
        case "tam-hurdle": return "Tam Hurdle"
        case "enid-sallow": return "Enid Sallow"
        case "walter-garth": return "Walter Garth"
        case "nell-foss": return "Nell Foss"
        default: return nil
        }
    }

    /// "I", "II", … for acts.
    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var left = max(0, n)
        var out = ""
        for (value, numeral) in table {
            while left >= value {
                out += numeral
                left -= value
            }
        }
        return out
    }

    /// "Reward: Early Riser and 100 coins."
    static func arcReward(_ reward: StoryStanding.Reward?) -> String? {
        guard let reward else { return nil }
        var parts: [String] = []
        if let title = reward.title { parts.append("the title \(title)") }
        if let ac = reward.ac, ac > 0 { parts.append(purse(ac)) }
        guard !parts.isEmpty else { return nil }
        return "Reward: " + list(parts) + "."
    }

    static let emptyJournalTitle = "No journeys yet"
    static let emptyJournalMessage = "Go for a ride, run or walk and it will show up here."
}
