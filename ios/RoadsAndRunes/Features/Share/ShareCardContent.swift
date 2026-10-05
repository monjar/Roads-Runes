import Foundation
import RoadsAndRunesArt
import RoadsAndRunesCore

/// What a share card says (0.7.3), worked out from Journey's end and the
/// character. By default it says nothing about where: no map, no trace, no
/// place or district. The trace is added only when the rider asks, and then
/// without its first and last kilometre (`TraceMask`). No rune glyph is drawn.
struct ShareCardContent: Equatable {
    struct Creature: Equatable {
        var name: String
        var mark: Mark
        /// "Fen Troll defeated! Finished with climbing." / "Health 31 / 400".
        var line: String
        var health: String?
    }

    var characterName: String
    var characterClass: CharacterClass
    /// The title worn, if any ("Wanderer").
    var title: String?
    /// "Wizard level 3".
    var classLine: String?
    var activity: Activity
    /// "Ride · 24.3 km" — what and how far, never where.
    var journeyLine: String
    var date: Date
    var creature: Creature?
    /// The entry's first sentence, unless it names a place.
    var sentence: String?
    /// Deeds reached on this journey: "Long Roads: Wayfarer".
    var deeds: [String]
    /// The masked trace, only when "Add my route" is on.
    var trace: [Coordinate]?

    static func make(summary: AdventureSummary, character: Character?, units: Units, trace: [Coordinate]? = nil) -> ShareCardContent {
        let activity = summary.ride.activity.flatMap { $0 == .unknown ? nil : $0 } ?? .ride
        let className = ClassStyle.name(character?.characterClass ?? .explorer)
        return ShareCardContent(
            characterName: character?.name ?? "A rider",
            characterClass: character?.characterClass ?? .explorer,
            title: character?.title.flatMap { $0.isEmpty ? nil : $0 },
            classLine: character.map { LoreCopy.classLevel(className, $0.classLevel) },
            activity: activity,
            journeyLine: "\(activity.verb) · \(UnitFormatter(units: units).distance(meters: summary.ride.distanceMeters))",
            date: summary.ride.startedAt,
            creature: creature(in: summary, units: units),
            sentence: firstSentence(of: summary.entryToRead, avoiding: placeNames(in: summary)),
            deeds: (summary.deeds?.reached ?? []).prefix(2).map { reached in
                reached.title.map { "\(reached.name): \($0)" } ?? reached.name
            },
            trace: trace
        )
    }

    /// The creature the journey defeated (the quarry first), else the one it weakened most.
    static func creature(in summary: AdventureSummary, units: Units) -> Creature? {
        let fights = FightCopy.ordered(summary.worldObjects?.fights ?? [], quarryId: summary.quarryId)
        if let report = fights.first(where: \.seenOff) ?? fights.first(where: { $0.outcome == "LOOSENED" }) {
            return Creature(
                name: report.name ?? "A creature",
                mark: .token(GameIcon.forSpecies(report.speciesId ?? ""), ring: report.bounty == true ? .gold : nil),
                // Defeated: "Fen Troll defeated! Finished with climbing." Weakened: the plain half, not when it leaves.
                line: report.seenOff ? FightCopy.line(report, units: units) : "\(report.name ?? "It") escaped, weakened.",
                health: "Health \(report.holdAfter) / \(report.holdMax)"
            )
        }
        // A creature from before fights were by effort: defeated, no health to tell.
        if let taken = summary.worldObjects?.claimed.first(where: { $0.kind == .monster }) {
            return Creature(name: taken.name, mark: .of(kind: .monster), line: "\(taken.name) defeated!", health: nil)
        }
        return nil
    }

    /// Every name of a place the summary knows: a sentence carrying one stays off the card.
    static func placeNames(in summary: AdventureSummary) -> [String] {
        var names = summary.discoveries.map(\.name)
        names += (summary.letters ?? []).compactMap(\.placeName)
        return names.filter { $0.count >= 3 }
    }

    /// The first sentence of `entry`, or nil when there is none or it names one of `places`.
    static func firstSentence(of entry: String?, avoiding places: [String] = []) -> String? {
        guard let entry = entry?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty else { return nil }
        var sentence = entry
        var index = entry.startIndex
        while index < entry.endIndex {
            let next = entry.index(after: index)
            if ".!?".contains(entry[index]), next == entry.endIndex || entry[next].isWhitespace {
                sentence = String(entry[...index])
                break
            }
            index = next
        }
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = sentence.lowercased()
        if places.contains(where: { lowered.contains($0.lowercased()) }) { return nil }
        return sentence.count > 160 ? String(sentence.prefix(157)) + "…" : sentence
    }
}
