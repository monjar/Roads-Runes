import RoadsAndRunesArt
import RoadsAndRunesCore

/// From what the phone says about a thing to its mark on the wrist. The phone
/// names icons as strings, and a newer phone may name one this Watch build has
/// not got, so every name falls back to one it has: the species, then the kind.
enum WristMarks {
    static func icon(_ name: String?, species: String? = nil, otherwise fallback: GameIcon) -> GameIcon {
        if let name, let icon = GameIcon(rawValue: name) { return icon }
        if let species, !species.isEmpty { return GameIcon.forSpecies(species) }
        return fallback
    }

    /// A thing near the route: a creature on its token (terracotta for the quarry,
    /// gold for a bounty), a chest by its tier, a rune stone, an objective's flag.
    static func mark(_ mark: WatchWorldMark) -> Mark {
        switch mark.kind {
        case WatchWorldMark.monster:
            let ring: Spot? = mark.isQuarry ? .terracotta : (mark.isBounty ? .gold : nil)
            return .token(icon(mark.icon, species: mark.speciesId, otherwise: .dragonHead), ring: ring)
        case WatchWorldMark.chest:
            return .chest(tier: mark.tier ?? 1)
        case WatchWorldMark.collectable:
            return .token(icon(mark.icon, otherwise: .runeStone))
        case WatchWorldMark.objective:
            return .objective
        case WatchWorldMark.legend:
            // A legend is always gold, quarry or not: there is only ever one.
            return .token(legendIcon(mark.icon, species: mark.speciesId), ring: .gold)
        case WatchWorldMark.lair:
            // Its seven tiles are too small for the wrist: the middle stands for them.
            return .token(icon(mark.icon, otherwise: .lair), ring: .sage)
        default:
            return .token(icon(mark.icon, otherwise: .mystery))
        }
    }

    /// How big a thing is drawn on the map: a legend largest, then what the journey is for.
    static func size(_ mark: WatchWorldMark) -> Double {
        if mark.isLegend { return 30 }
        if mark.isQuarry { return 24 }
        switch mark.kind {
        case WatchWorldMark.objective, WatchWorldMark.lair: return 20
        default: return 16
        }
    }

    /// A stop as its place mark; nil from an older phone, which sends no kind.
    static func stop(_ stop: WatchStop) -> Mark? {
        guard let category = stop.category else { return nil }
        return .token(GameIcon.forPlace(category), ring: stop.requested ? .terracotta : nil)
    }

    /// The creature being fought, ringed in terracotta when it is the quarry. A
    /// legend's phases ring it already, so its mark goes bare.
    static func fight(_ fight: WatchFight) -> Mark {
        if fight.isLegend { return .token(legendIcon(fight.icon, species: fight.speciesId)) }
        return .token(icon(fight.icon, species: fight.speciesId, otherwise: .dragonHead), ring: fight.quarry ? .terracotta : nil)
    }

    /// A legend's own drawing: the one the phone names, else its species'.
    static func legendIcon(_ name: String?, species: String?) -> GameIcon {
        icon(name, otherwise: GameIcon.forLegend(species ?? ""))
    }

    /// The overlay's mark: what the phone named (the creature defeated, the item
    /// found), else what happened: a sword, an open chest, a rune stone, a flag.
    static func claim(_ event: WatchObjectiveCompleted) -> Mark {
        let fallback: GameIcon
        switch event.outcome {
        case "GONE": fallback = .sword
        case "OPENED": fallback = .openChest
        case "FOUND": fallback = .runeStone
        case WatchObjectiveCompleted.Outcome.phase:
            // Phase broken: the legend's own mark, in its gold ring.
            return .token(icon(event.icon, otherwise: .dragonHead), ring: .gold)
        default: fallback = .flag
        }
        return .token(icon(event.icon, otherwise: fallback), ring: ring(rarity: event.rarity))
    }

    /// The overlay's heading. The phone sends GONE for a creature (a wire word older
    /// Watches know); it reads DEFEATED. A legend's phase reads as VOICE has it.
    static func heading(_ event: WatchObjectiveCompleted) -> String {
        switch event.outcome {
        case "GONE": return "DEFEATED"
        case WatchObjectiveCompleted.Outcome.phase: return "PHASE BROKEN!"
        case .some(let outcome): return outcome
        case .none: return "DONE"
        }
    }

    /// A line of Journey's end: an item, a rune stone or a place.
    static func find(_ find: WatchFind) -> Mark {
        .token(icon(find.icon, otherwise: .sparkles), ring: ring(rarity: find.rarity))
    }

    /// Journey's end's legend line: its mark in gold.
    static func legendLine(_ line: WatchEndLine) -> Mark {
        .token(icon(line.icon, otherwise: .dragonHead), ring: .gold)
    }

    /// The lair's line: its great chest once claimed, else the lair's own mark.
    static func lairLine(_ line: WatchEndLine) -> Mark {
        .token(icon(line.icon, otherwise: .lair), ring: line.icon == GameIcon.greatChest.rawValue ? .gold : .sage)
    }

    /// Buried treasure dug up.
    static func treasureLine(_ line: WatchEndLine) -> Mark {
        .token(icon(line.icon, otherwise: .treasureMap), ring: .gold)
    }

    static func ring(rarity: String?) -> Spot? {
        switch rarity?.uppercased() {
        case "LEGENDARY": return .gold
        case "RARE": return .scribe
        default: return nil
        }
    }

    /// Common, Rare or Legendary; nothing for what has no rarity.
    static func rarityWord(_ rarity: String?) -> String? {
        switch rarity?.uppercased() {
        case "COMMON": return "Common"
        case "RARE": return "Rare"
        case "LEGENDARY": return "Legendary"
        default: return nil
        }
    }
}
