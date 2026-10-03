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
