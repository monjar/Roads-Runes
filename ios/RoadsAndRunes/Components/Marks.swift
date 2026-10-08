import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// From the app's things to their faces (RoadsAndRunesArt). Every view that
/// shows a creature, a chest, a piece or a trade asks here, so the map, the
/// cards, the codex and the reckoning cannot disagree about what a thing looks like.
extension Mark {
    static func of(_ object: WorldObject) -> Mark {
        // A legend as a journey fights it, and a lair (0.8.0), before the kinds.
        if object.isLegend { return .legend(icon: object.monster?.sigil?.icon, speciesId: object.monster?.speciesId) }
        if object.isLair { return .lair }
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
    /// A creature the server named no face for: drawn as a dragon's head. From 0.7.2
    /// the server names its icon, and that is drawn first.
    init(_ sigil: CreatureSigil?) {
        self.init(body: sigil?.body ?? "shade", feature: sigil?.feature ?? "hood", mark: sigil?.mark ?? "mist", icon: sigil?.icon)
    }
}

/// The faces of what you carry (0.7.2): gear by its icon (or its id), a
/// consumable, a find, a stall offer, a level's reward, each ringed by rarity.
extension Mark {
    static func of(_ item: GearItem) -> Mark {
        .item(GameIcon.named(item.icon, or: .forItem(item.itemId)), rarity: item.rarity)
    }

    static func of(_ stack: ConsumableStack) -> Mark {
        .item(GameIcon.named(stack.icon, or: .forConsumable(stack.id)), rarity: stack.id == ConsumableId.sealedChestRare ? ItemRarity.rare : nil)
    }

    static func of(_ found: ItemFound) -> Mark {
        let fallback: GameIcon = found.isGear ? .forItem(found.itemId ?? "") : .forConsumable(found.consumable ?? "")
        return .item(GameIcon.named(found.icon, or: fallback), rarity: found.rarity)
    }

    static func of(_ offer: StallOffer) -> Mark {
        // A look (0.9.0): the ink swirl for an ink, the class crest's laurels for a frame.
        if offer.isCosmetic {
            return .token(GameIcon.named(offer.icon, or: offer.lookKind == .ink ? .inkSwirl : .laurels), ring: .gold)
        }
        let fallback: GameIcon = offer.isGear ? .forItem(offer.itemId ?? "") : .forConsumable(offer.consumable ?? "")
        return .item(GameIcon.named(offer.icon, or: fallback), rarity: offer.rarity)
    }

    static func of(_ reward: QuestRewardItem) -> Mark {
        .item(GameIcon.named(reward.icon, or: .forItem(reward.itemId)), rarity: reward.rarity)
    }

    static func of(_ reward: LevelReward) -> Mark {
        let fallback: GameIcon
        switch reward.kind {
        case "SLOT": fallback = .sparkles
        case "RUNE_SLOT": fallback = .runeStone
        case "STALL": fallback = .shop
        case "TITLE": fallback = .laurels
        default: fallback = .forConsumable(reward.consumable ?? "")
        }
        return .token(GameIcon.named(reward.icon, or: fallback))
    }
}

/// A legend's face (0.8.0): its drawing on a gold-ringed token.
extension Mark {
    static func of(_ legend: Legend) -> Mark { .legend(icon: legend.icon, speciesId: legend.speciesId) }
    static func of(_ legend: LegendSummary) -> Mark { .legend(icon: legend.icon, speciesId: legend.speciesId) }
}

extension InkPalette {
    /// What the app draws on: cream paper, as the rest of the design system.
    static var app: InkPalette { .phone }
}
