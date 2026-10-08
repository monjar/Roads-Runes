import Foundation

/// The words for districts, the Atlas and the festivals (0.9.0, docs/VOICE.md): a
/// district's title always after a comma, "in the fog" under 10%, a percentage
/// only once the roads are known, "yours" and "was yours", "District complete!".
public enum DistrictCopy {
    public static let complete = "District complete!"
    public static let planButton = "Plan a ride here"
    public static let inTheFog = "in the fog"

    /// "Rotherhithe, the Riverlands"; under 10% explored or with no title yet, "Rotherhithe, in the fog".
    public static func fullName(name: String, title: String?, percent: Double?) -> String {
        if let percent, percent < DistrictRules.titleAtPercent { return "\(name), \(inTheFog)" }
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return "\(name), \(inTheFog)" }
        return "\(name), \(title)"
    }

    /// "47% explored"; until the roads are known, "12 tiles explored".
    public static func progress(percent: Double?, tiles: Int) -> String {
        if let percent { return "\(whole(percent))% explored" }
        return "\(tiles) \(tiles == 1 ? "tile" : "tiles") explored"
    }

    /// "Rotherhithe is yours. 5 coins a week while you keep visiting."
    public static func yours(_ name: String, weeklyCoins: Int) -> String {
        "\(name) is yours. \(LoreCopy.purse(weeklyCoins)) a week while you keep visiting."
    }

    /// "Rotherhithe was yours. Visit again to make it yours." Nothing is lost.
    public static func wasYours(_ name: String) -> String {
        "\(name) was yours. Visit again to make it yours."
    }

    /// The district's standing in one line, for its page and the list.
    public static func standing(_ district: District) -> String? {
        if district.completed, district.yours { return "\(complete) \(yours(district.name, weeklyCoins: district.weeklyCoins))" }
        if district.yours { return yours(district.name, weeklyCoins: district.weeklyCoins) }
        if district.wasYours { return wasYours(district.name) }
        if let percent = district.percent {
            let left = DistrictRules.yoursAtPercent - percent
            if left > 0 { return "\(whole(left.rounded(.up)))% more to make it yours." }
        }
        return nil
    }

    /// For Next up, only near a milestone: "Rotherhithe is 47% explored. 3% to make it
    /// yours." Nil when the roads are not known or no milestone is within `within`%.
    public static func nearMilestone(_ district: District, within: Double = 10) -> String? {
        if district.wasYours, !district.yours { return wasYours(district.name) }
        guard let percent = district.percent else { return nil }
        let now = "\(district.name) is \(whole(percent))% explored."
        if !district.yours, !district.wasYours, percent < DistrictRules.yoursAtPercent, DistrictRules.yoursAtPercent - percent <= within {
            return "\(now) \(whole((DistrictRules.yoursAtPercent - percent).rounded(.up)))% to make it yours."
        }
        if !district.completed, percent < DistrictRules.completeAtPercent, DistrictRules.completeAtPercent - percent <= within {
            return "\(now) \(whole((DistrictRules.completeAtPercent - percent).rounded(.up)))% to complete it."
        }
        return nil
    }

    /// One district on Journey's end: "Rotherhithe, the Riverlands · 6 new tiles · 47% explored".
    public static func outcome(_ outcome: DistrictOutcome) -> String {
        var parts = [outcome.fullName]
        if outcome.newTiles > 0 { parts.append("\(outcome.newTiles) new \(outcome.newTiles == 1 ? "tile" : "tiles")") }
        if let percent = outcome.percent { parts.append("\(whole(percent))% explored") }
        return parts.joined(separator: " · ")
    }

    /// "Rotherhithe is yours!" for a district made yours on a journey.
    public static func becameYours(_ name: String) -> String { "\(name) is yours!" }

    /// "Your districts paid 10 coins this week: Rotherhithe, Bermondsey." Round a
    /// festival: "…this week, doubled for the festival: …".
    public static func pay(_ pay: DistrictPay) -> String {
        let names = pay.districts.isEmpty ? "" : ": \(pay.districts.joined(separator: ", "))"
        let festival = pay.doubled ? ", doubled for the festival" : ""
        return "Your districts paid \(LoreCopy.purse(pay.coins)) this week\(festival)\(names)."
    }

    /// "First visit 3 Oct 2026".
    public static func visit(_ label: String, _ date: Date?) -> String? {
        guard let date else { return nil }
        return "\(label) \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    static func whole(_ value: Double) -> Int { Int(max(0, min(100, value)).rounded(.down)) }
}

/// The four festivals (0.9.0): Spring Festival, Midsummer, Harvest, Midwinter.
public enum SeasonCopy {
    /// "Midsummer" from "MIDSUMMER", "midsummer" or "spring-festival" from the arc's `season`.
    public static func name(_ season: String?) -> String? {
        guard let key = season.map(normalise), !key.isEmpty else { return nil }
        switch key {
        case "spring", "springfestival", "ladyday": return "Spring Festival"
        case "midsummer", "summer": return "Midsummer"
        case "harvest", "michaelmas", "autumn": return "Harvest"
        case "midwinter", "winter", "christmas": return "Midwinter"
        default:
            return season.map { $0.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized }
        }
    }

    /// The `GameIcon` raw name for a festival.
    public static func icon(_ season: String?) -> String {
        switch season.map(normalise) ?? "" {
        case "spring", "springfestival", "ladyday": return "springFestival"
        case "midsummer", "summer": return "midsummer"
        case "harvest", "michaelmas", "autumn": return "harvest"
        case "midwinter", "winter", "christmas": return "midwinter"
        default: return "sparkles"
        }
    }

    /// "Ends 7 Jul": the last day the festival is open. The server's `endsAt` is the
    /// midnight (UTC) after it, and its windows are whole days, so the day is UTC's.
    public static func ends(_ date: Date, locale: Locale = .current) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        style.locale = locale
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        return "Ends \(date.addingTimeInterval(-1).formatted(style))"
    }

    /// The festival's window is fourteen days from its day.
    public static let windowDays = 14

    static func normalise(_ season: String) -> String {
        season.lowercased().filter { $0.isLetter }
    }
}
