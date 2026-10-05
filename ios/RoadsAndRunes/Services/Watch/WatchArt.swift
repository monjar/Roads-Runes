import RoadsAndRunesArt
import RoadsAndRunesCore

/// The `GameIcon` names the Watch draws things with. Core carries them as plain
/// strings (it knows nothing of the art), so the phone, which does, names them
/// here, the same way its own map draws them (`Mark.of`).
enum WatchArt {
    static func icon(for object: WorldObject) -> String? {
        switch object.kind {
        case .monster:
            // The species first: it names every creature the art knows; a face
            // the server describes covers one it does not.
            if let species = object.monster?.speciesId, GameIcon.forSpecies(species) != .dragonHead {
                return GameIcon.forSpecies(species).rawValue
            }
            return GameIcon.forSigil(Sigil(object.monster?.sigil)).rawValue
        case .chest:
            return GameIcon.chest.rawValue
        case .collectable:
            return object.setId == "COINS" ? GameIcon.coins.rawValue : GameIcon.runeStone.rawValue
        case .unknown:
            return nil
        }
    }

    /// What the claim overlay shows: the creature defeated or the piece picked up,
    /// and a chest standing open.
    static func claimIcon(for object: WorldObject) -> String? {
        object.kind == .chest ? GameIcon.openChest.rawValue : icon(for: object)
    }

    /// A place by its category, for a stop and a new place on Journey's end.
    static func icon(for category: DiscoveryCategory) -> String? {
        GameIcon.forPlace(category.rawValue).rawValue
    }

    /// A quest on Next up (0.7.3): its class's mark, a scroll for anyone's.
    static func icon(for quest: Quest) -> String? {
        switch quest.characterClass {
        case .explorer, .wizard, .warrior, .scribe: return GameIcon.forClass(quest.characterClass.rawValue).rawValue
        default: return GameIcon.scroll.rawValue
        }
    }
}
