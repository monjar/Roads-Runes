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
        default:
            return .token(icon(mark.icon, otherwise: .mystery))
        }
    }

    /// How big a thing is drawn on the map: what the journey is for stands out.
    static func size(_ mark: WatchWorldMark) -> Double {
        if mark.isQuarry { return 24 }
        return mark.kind == WatchWorldMark.objective ? 20 : 16
    }

    /// A stop as its place mark; nil from an older phone, which sends no kind.
    static func stop(_ stop: WatchStop) -> Mark? {
        guard let category = stop.category else { return nil }
        return .token(GameIcon.forPlace(category), ring: stop.requested ? .terracotta : nil)
    }

    /// The creature being fought, ringed in terracotta when it is the quarry.
    static func fight(_ fight: WatchFight) -> Mark {
        .token(icon(fight.icon, species: fight.speciesId, otherwise: .dragonHead), ring: fight.quarry ? .terracotta : nil)
    }

    /// The overlay's mark: what the phone named (the creature defeated, the item
    /// found), else what happened: a sword, an open chest, a rune stone, a flag.
    static func claim(_ event: WatchObjectiveCompleted) -> Mark {
        let fallback: GameIcon
        switch event.outcome {
        case "GONE": fallback = .sword
        case "OPENED": fallback = .openChest
        case "FOUND": fallback = .runeStone
        default: fallback = .flag
        }
        return .token(icon(event.icon, otherwise: fallback), ring: ring(rarity: event.rarity))
    }

    /// A line of Journey's end: an item, a rune stone or a place.
    static func find(_ find: WatchFind) -> Mark {
        .token(icon(find.icon, otherwise: .sparkles), ring: ring(rarity: find.rarity))
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
