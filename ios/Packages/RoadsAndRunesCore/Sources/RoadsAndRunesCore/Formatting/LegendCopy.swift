import Foundation

/// The words for legends, lairs and treasure maps (0.8.0, docs/VOICE.md): what
/// it is and what it costs first, numbers with a label, an exclamation mark only
/// for a celebration.
public enum LegendCopy {
    public static let phaseBroken = "Phase broken!"
    public static let moveButton = "Move it once"
    public static let planButton = "Plan a ride here"

    /// "A legend has woken: the Fog Dragon".
    public static func woke(_ name: String) -> String {
        "A legend has woken: \(lowerArticle(name))"
    }

    /// "Defeat 2 more creatures and a legend wakes."
    public static func untilNext(_ creatures: Int) -> String {
        creatures <= 0
            ? "A legend wakes soon."
            : "Defeat \(creatures) more \(creatures == 1 ? "creature" : "creatures") and a legend wakes."
    }

    /// "Health 360 / 500 in this phase".
    public static func health(_ phase: LegendPhase) -> String {
        "Health \(phase.healthLeft) / \(phase.healthMax)"
    }

    /// "Heals 50 a week if left alone. Sleeps after 4 weeks."
    public static func healsAndSleeps(healsPerWeek: Int?, sleepsAfterDays: Int?) -> String {
        var parts: [String] = []
        if let heals = healsPerWeek, heals > 0 { parts.append("Heals \(heals) a week if left alone.") }
        if let days = sleepsAfterDays, days > 0 {
            let weeks = days % 7 == 0 ? "\(days / 7) \(days / 7 == 1 ? "week" : "weeks")" : "\(days) days"
            parts.append("Sleeps after \(weeks).")
        }
        parts.append("It never takes anything from you.")
        return parts.joined(separator: " ")
    }

    /// One kind of effort against this phase, with its number: "Exploring: 30 per
    /// new tile", "Distance: 20 per km", "Climbing: 25 per 10 m", "Rune shape: 200, once a day".
    public static func effort(_ kind: String, perUnit: Double, units: Units = .metric) -> String {
        let formatter = UnitFormatter(units: units)
        let name = LoreCopy.kind(kind).capitalizedFirst
        func number(_ value: Double) -> String {
            value >= 10 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
        }
        switch kind.uppercased() {
        case "ROAD":
            let per = formatter.isImperial ? UnitFormatter.metersPerMile : 1000
            return "\(name): \(number(perUnit * per)) per \(formatter.distanceUnitLabel)"
        case "GROUND": return "\(name): \(number(perUnit)) per new tile"
        case "CLIMB":
            let step = formatter.isImperial ? 30 / UnitFormatter.feetPerMeter : 10
            return "\(name): \(number(perUnit * step)) per \(formatter.elevation(meters: step))"
        case "RUNE", "WORD": return "\(name): \(number(perUnit)), once a day"
        default: return "\(name): \(number(perUnit))"
        }
    }

    /// "5 Oct · 140 damage", a journey on its page.
    public static func journey(_ journey: LegendJourney, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let damage = "\(journey.damage) damage"
        guard let date = journey.date else { return damage }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        return "\(date.formatted(style)) · \(damage)"
    }

    /// The journey's line for a legend: the server's when it sent one.
    /// "Phase broken! The Fog Dragon is down to its last phase." or
    /// "The Fog Dragon took 140 damage. 360 left in this phase."
    public static func outcome(_ outcome: LegendOutcome) -> String {
        if let line = outcome.line, !line.isEmpty { return line }
        if outcome.defeated { return "\(outcome.name) is defeated!" }
        if outcome.phaseBroken {
            let left = Legend.phaseCount - outcome.phaseAfter + 1
            let rest = left <= 1 ? "is down to its last phase." : "has \(RewardCopy.spelled(left)) phases left."
            return "\(phaseBroken) \(outcome.name) \(rest)"
        }
        if outcome.damage <= 0 { return "\(outcome.name) wasn't hurt this time." }
        return "\(outcome.name) took \(outcome.damage) damage. \(outcome.phaseLeft) left in this phase."
    }

    /// "Exploring 120 · distance 40", the damage by kind, biggest first.
    public static func kinds(_ kinds: [String: Int]) -> String? {
        let parts = kinds.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { "\(LoreCopy.kind($0.key)) \($0.value)" }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ").capitalizedFirst
    }

    /// "the Fog Dragon" from "The Fog Dragon", inside a sentence.
    static func lowerArticle(_ name: String) -> String {
        name.hasPrefix("The ") ? "the " + name.dropFirst(4) : name
    }
}

/// The words for a lair (0.8.0).
public enum LairCopy {
    /// "Visit 5 of its 7 tiles by 14 Oct."
    public static func task(_ lair: LairInfo, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let base = "Visit \(lair.need) of its \(max(lair.cells.count, 7)) tiles"
        guard let ends = lair.endsAt else { return base + "." }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        return "\(base) by \(ends.formatted(style))."
    }

    /// "3 / 5 tiles".
    public static func progress(visited: Int, need: Int) -> String {
        "\(min(visited, need)) / \(need) tiles"
    }

    /// What its great chest holds, said first.
    public static let reward = "Its great chest holds 250 coins, a Rare item and a sealed chest."

    /// Journey's end: "Southwark Park lair: 4 / 5 tiles." or "Southwark Park lair done! A great chest opened."
    public static func outcome(_ outcome: LairOutcome) -> String {
        if let line = outcome.line, !line.isEmpty { return line }
        return outcome.done
            ? "\(outcome.name) done! You opened its great chest."
            : "\(outcome.name): \(progress(visited: outcome.visited, need: outcome.need))."
    }
}

/// The words for a treasure map (0.8.0).
public enum TreasureCopy {
    public static let useButton = "Use treasure map"
    /// Said under a clue: what to do, plainly.
    public static let howTo = "Pass within 40 m of it on a journey and it opens."
    public static let found = "You found the buried treasure!"

    /// Journey's end's line for a treasure opened.
    public static func outcome(_ found: TreasureFound) -> String {
        var line = found.line.flatMap { $0.isEmpty ? nil : $0 } ?? Self.found
        if let coins = found.coins, coins > 0, !line.contains("coin") { line += " \(LoreCopy.earned(coins))" }
        return line
    }
}

/// Where each Hard rune is found (0.8.0): a legend's when it is defeated, and
/// Ingwaz from a lair's great chest.
public enum HardRunes {
    public static let ids = ["uruz", "thurisaz", "hagalaz", "nauthiz", "isa", "ingwaz"]

    /// The legend that leaves each, by species id.
    public static let leftBy: [String: (speciesId: String, name: String)] = [
        "hagalaz": ("fog-dragon", "the Fog Dragon"),
        "isa": ("water-wyrm", "the Water Wyrm"),
        "uruz": ("hill-king", "the Hill King"),
        "nauthiz": ("trail-wyrm", "the Trail Wyrm"),
        "thurisaz": ("rune-golem", "the Rune Golem"),
    ]

    /// "Defeat the Fog Dragon to take it." / "Found in a lair's great chest."; nil for any other rune.
    public static func howToFind(_ runeId: String) -> String? {
        let id = runeId.lowercased()
        if id == "ingwaz" { return "Found in a lair's great chest." }
        guard let legend = leftBy[id] else { return nil }
        return "Defeat \(legend.name) to take it."
    }
}
