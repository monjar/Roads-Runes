import Foundation

/// The world's words for the app's things (docs/WORLD.md), in one place so the
/// phone and the Watch say them the same way and a rename is one edit.
public enum LoreCopy {
    /// Coins, never "AC": "60 coins", "1 coin".
    public static func purse(_ amount: Int) -> String {
        "\(amount.formatted()) \(amount == 1 ? "coin" : "coins")"
    }

    /// "+60 coins", for a claim or a line in the reckoning.
    public static func earned(_ amount: Int) -> String {
        "+\(purse(amount))"
    }

    /// Days in a row are days kept: "1 day kept", "6 days kept".
    public static func daysKept(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days") kept"
    }

    /// An unspent ability point is a knack to choose.
    public static func knacksToChoose(_ count: Int) -> String {
        "\(count) \(count == 1 ? "knack" : "knacks") to choose"
    }

    /// What a level-up brings: "A new knack: Trail Sense".
    public static func newKnack(_ name: String) -> String {
        "A new knack: \(name)"
    }

    /// "Go out as an Explorer": the trade is chosen, then the road.
    public static func goOutAs(_ trade: String) -> String {
        let article = "AEIOU".contains(trade.prefix(1)) ? "an" : "a"
        return "Go out as \(article) \(trade)"
    }

    public static let loading = "Unfolding the map."
    public static let reckoning = "The reckoning"
    public static let closeTheBook = "Close the book"
    public static let changeOfTrade = "Change of trade"
}

public extension LoreCopy {
    /// The five kinds of effort, as the world says them.
    static func kind(_ kind: String) -> String {
        switch kind.uppercased() {
        case "ROAD": return "the road"
        case "GROUND": return "new ground"
        case "CLIMB": return "height"
        case "RUNE": return "a rune"
        case "WORD": return "the word"
        default: return kind.lowercased()
        }
    }

    /// What a rune comes out as on a road.
    static func roadForm(_ form: String?) -> String? {
        switch form?.uppercased() {
        case "LOOP": return "a loop"
        case "TRIANGLE": return "a triangle"
        case "SQUARE": return "a square"
        case "ZIGZAG": return "a zigzag"
        case "NOTE": return "a note written"
        case "STOP": return "a stop"
        default: return nil
        }
    }

    /// "Wants the road and a rune (Dagaz, a square)."
    static func wants(_ kinds: [String], rune: String? = nil, runeForm: String? = nil) -> String {
        let words = kinds.map { kind -> String in
            if kind.uppercased() == "RUNE", let rune {
                let form = roadForm(runeForm).map { ", \($0)" } ?? ""
                return "a rune (\(rune)\(form))"
            }
            return Self.kind(kind)
        }
        return "Wants \(words.joined(separator: " and "))."
    }

    static func doesNotMind(_ kinds: [String]) -> String {
        "Does not mind \(kinds.map(kind).joined(separator: " or "))."
    }

    static let emptyJournalTitle = "Nothing written yet"
    static let emptyJournalMessage = "The journal fills itself. It only needs you to go out."
}
