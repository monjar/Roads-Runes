import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// From the app's things to their faces (RoadsAndRunesArt). Every view that
/// shows a creature, a chest, a piece or a trade asks here, so the map, the
/// cards, the codex and the reckoning cannot disagree about what a thing looks like.
extension Mark {
    static func of(_ object: WorldObject) -> Mark {
        switch object.kind {
        case .monster:
            return .creature(Sigil(object.monster?.sigil), tier: object.tier, bounty: object.isBounty)
        case .chest:
            return .chest(tier: object.tier)
        case .collectable:
            switch object.setId {
            case "RUNES": return .rune((object.piece ?? "").lowercased())
            case "COINS": return .coin
            default: return .worn
            }
        case .unknown:
            return .worn
        }
    }

    /// A kind alone, for places that know nothing more (an old server's bounty card).
    static func of(kind: WorldObjectKind, bounty: Bool = false) -> Mark {
        switch kind {
        case .monster: return .creature(Sigil(nil), bounty: bounty)
        case .chest: return .chest(tier: 1)
        case .collectable: return .coin
        case .unknown: return .worn
        }
    }

    static func crest(_ characterClass: CharacterClass) -> Mark {
        .crest(characterClass.rawValue.lowercased())
    }
}

extension Sigil {
    /// A creature the server named no face for: drawn as a dragon's head.
    init(_ sigil: CreatureSigil?) {
        self.init(body: sigil?.body ?? "shade", feature: sigil?.feature ?? "hood", mark: sigil?.mark ?? "mist")
    }
}

extension InkPalette {
    /// What the app draws on: cream paper, as the rest of the design system.
    static var app: InkPalette { .phone }
}
