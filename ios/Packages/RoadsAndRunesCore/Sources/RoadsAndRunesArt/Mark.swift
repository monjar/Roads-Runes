import CoreGraphics
import Foundation

/// A creature's face, as the server describes it: a body, a feature and what
/// it stands on (`world_objects.json`, `sigil`). From 0.7.2 the server names the
/// icon too (a `GameIcon` raw name), so a new creature needs no new pair here.
public struct Sigil: Hashable, Sendable, Codable {
    public let body: String
    public let feature: String
    public let mark: String
    /// The `GameIcon` raw name ("hedgeDragon"); nil from a server before 0.7.2.
    public let icon: String?

    public init(body: String, feature: String, mark: String, icon: String? = nil) {
        self.body = body
        self.feature = feature
        self.mark = mark
        self.icon = icon
    }
}

/// Everything in the game with a face. One type, so every place that shows a
/// thing (a map marker, a card, a codex page, the Watch) asks for the same mark
/// and gets the same drawing, and an illustration can later replace any of them
/// in one place (`ArtSlots`).
public enum Mark: Hashable, Sendable {
    /// A rune by id ("raido"), cut into a stone.
    case rune(String)
    /// A trade's crest by class ("explorer").
    case crest(String)
    /// A creature. `tier` picks the frame (an elder's is doubled or notched),
    /// `bounty` gilds it, `unmet` leaves only the silhouette.
    case creature(Sigil, tier: Int = 1, bounty: Bool = false, unmet: Bool = false)
    case chest(tier: Int)
    case coin
    case purse
    /// A kind of effort a thing wants: ROAD, GROUND, CLIMB, RUNE, WORD.
    case kind(String)
    /// A place on the map by its kind ("PUB", "NATURE", "VIEWPOINT"…), on a token.
    case place(String)
    /// The player on the map, by activity ("RIDE", "RUN", "WALK").
    case rider(String)
    /// Any icon on a paper token, its ring in a spot colour if given.
    case token(GameIcon, ring: Spot? = nil)
    /// Any icon bare, in ink or a spot colour, for a row or a pill.
    case icon(GameIcon, spot: Spot? = nil)
    /// The fallback for anything the app has no drawing for yet.
    case worn

    /// A stable id for caching and for the seeded wobble.
    public var id: String {
        switch self {
        case let .rune(id): return "rune:\(id)"
        case let .crest(id): return "crest:\(id)"
        case let .creature(sigil, tier, bounty, unmet):
            return "creature:\(sigil.body)/\(sigil.feature)/\(sigil.mark)/\(sigil.icon ?? "-")/\(tier)/\(bounty)/\(unmet)"
        case let .chest(tier): return "chest:\(tier)"
        case .coin: return "coin"
        case .purse: return "purse"
        case let .kind(kind): return "kind:\(kind)"
        case let .place(kind): return "place:\(kind)"
        case let .rider(activity): return "rider:\(activity)"
        case let .token(icon, ring): return "token:\(icon.rawValue)/\(ring?.rawValue ?? "-")"
        case let .icon(icon, spot): return "icon:\(icon.rawValue)/\(spot?.rawValue ?? "-")"
        case .worn: return "worn"
        }
    }

    /// The trade a crest belongs to, as the colour of its field.
    static func spot(forCrest id: String) -> Spot {
        switch id.lowercased() {
        case "explorer": return .sage
        case "wizard": return .wizard
        case "warrior": return .terracotta
        case "scribe": return .scribe
        default: return .stone
        }
    }
}

public extension Mark {
    /// A quest's marker: a scroll on a token.
    static let quest = Mark.token(.scroll, ring: .terracotta)
    /// Where a quest's objective is.
    static let objective = Mark.token(.flag, ring: .terracotta)
    /// A place not found yet.
    static let mystery = Mark.token(.mystery)
    /// A spot the player picked: a dropped pin or a search result.
    static let pin = Mark.place("PIN")
    /// A lamp left out.
    static let lamp = Mark.token(.lantern, ring: .gold)

    /// An item or a find on a token, its ring by rarity: plain for Common, blue
    /// for Rare, gold for Legendary (0.7.2).
    static func item(_ icon: GameIcon, rarity: String?) -> Mark {
        .token(icon, ring: Spot.forRarity(rarity))
    }

    /// A legend (0.8.0): its own drawing on a token with a gold ring, by the icon
    /// the server names or else by its species.
    static func legend(icon: String?, speciesId: String? = nil) -> Mark {
        .token(GameIcon.named(icon, or: GameIcon.forLegend(speciesId ?? "")), ring: .gold)
    }

    /// A lair (0.8.0): the cave on a sage token.
    static let lair = Mark.token(.lair, ring: .sage)
    /// A lair's reward (0.8.0).
    static let greatChest = Mark.token(.greatChest, ring: .gold)
    /// A treasure map's clue (0.8.0): never a place on the map, only this.
    static let treasureMap = Mark.token(.treasureMap, ring: .terracotta)
}

public extension Spot {
    /// The ring of an item's token: none for Common, scribe blue for Rare, gold for Legendary.
    static func forRarity(_ rarity: String?) -> Spot? {
        switch rarity?.uppercased() {
        case "RARE": return .scribe
        case "LEGENDARY": return .gold
        default: return nil
        }
    }
}

public extension GameIcon {
    /// A creature's icon from its sigil: each of the twelve has its own body and
    /// feature, so the pair names it without the server sending a species.
    static func forSigil(_ sigil: Sigil) -> GameIcon {
        // The server's own name for it first (0.7.2): the twenty-four by name.
        if let named = sigil.icon.flatMap(GameIcon.init(rawValue:)) { return named }
        switch (sigil.body, sigil.feature) {
        case ("wisp", "hood"): return .ghost
        case ("hulk", "horns"): return .troll
        case ("wyrm", "fins"): return .seaSerpent
        case ("shade", "hook"): return .witch
        case ("bird", _): return .raven
        case ("beast", "antlers"): return .deer
        case ("hulk", "moss"): return .rockGolem
        case ("armour", "visor"): return .visoredHelm
        case ("armour", "ember"): return .ifrit
        case ("wyrm", "wings"): return .wyvern
        case ("wisp", "ember"): return .fairy
        case ("beast", "ember"): return .wolfHead
        case ("wyrm", _): return .wyvern
        case ("hulk", _): return .troll
        case ("beast", _): return .wolfHead
        case ("wisp", _): return .ghost
        case ("armour", _): return .visoredHelm
        // A creature the server named no face for.
        default: return .dragonHead
        }
    }

    /// A creature's icon by species id, for what knows only that (a fight report).
    static func forSpecies(_ id: String) -> GameIcon {
        switch id {
        case "bog-wraith": return .ghost
        case "fen-troll": return .troll
        case "tide-serpent": return .seaSerpent
        case "mire-hag": return .witch
        case "rook-lord": return .raven
        case "grey-stag": return .deer
        case "moss-golem": return .rockGolem
        case "hollow-sentry": return .visoredHelm
        case "ash-warden": return .ifrit
        case "gutter-drake": return .wyvern
        case "lamp-sprite": return .fairy
        case "cinder-hound": return .wolfHead
        // The twelve that came in 0.7.2.
        case "hedge-dragon": return .hedgeDragon
        case "hill-wyvern": return .hillWyvern
        case "culvert-imp": return .culvertImp
        case "bridge-ogre": return .bridgeOgre
        case "stile-boggart": return .stileBoggart
        case "milestone-goblin": return .milestoneGoblin
        case "gatehouse-gargoyle": return .gatehouseGargoyle
        case "bramble-wolf": return .brambleWolf
        case "rooftop-griffin": return .rooftopGriffin
        case "marsh-wisp": return .marshWisp
        case "stone-giant": return .stoneGiant
        case "tavern-brownie": return .tavernBrownie
        default: return .dragonHead
        }
    }

    /// An item of gear by its id (`gear.json`), for what knows only the id. The
    /// server sends the icon by name as well; that wins where it is known.
    static func forItem(_ id: String) -> GameIcon {
        switch id {
        case "tin-bell": return .tinBell
        case "drovers-bell": return .droversBell
        case "unrung-bell": return .unrungBell
        case "candle-stub": return .candleStub
        case "bullseye-lantern": return .bullseyeLantern
        case "wreckers-light": return .wreckersLight
        case "saddle-roll": return .saddleRoll
        case "tinkers-satchel": return .tinkersSatchel
        case "poachers-pocket": return .poachersPocket
        case "folded-map": return .foldedMap
        case "pedlars-roadbook": return .pedlarsRoadbook
        case "cartographers-atlas": return .cartographersAtlas
        case "hagstone": return .hagstone
        case "rowan-twig": return .rowanTwig
        case "runesmiths-nail": return .runesmithsNail
        default: return .sparkles
        }
    }

    /// A consumable by its id: a lamp, a map piece, a rest token, a sealed chest.
    static func forConsumable(_ id: String) -> GameIcon {
        switch id.uppercased() {
        case "LAMP": return .lantern
        case "MAP_FRAGMENT": return .treasureMap
        case "REST_TOKEN": return .restToken
        case "SEALED_CHEST_COMMON", "SEALED_CHEST_RARE", "SEALED_CHEST": return .chest
        case "TREASURE_MAP": return .treasureMap
        default: return .sparkles
        }
    }

    /// A legend by its species id (`legends.json`, 0.8.0); the server names the
    /// icon as well, and that wins where it is known.
    static func forLegend(_ id: String) -> GameIcon {
        switch id {
        case "fog-dragon": return .fogDragon
        case "water-wyrm": return .waterWyrm
        case "hill-king": return .hillKing
        case "trail-wyrm": return .trailWyrm
        case "rune-golem": return .runeGolem
        default: return .dragonHead
        }
    }

    /// A gear slot, drawn faint while it is empty: the plainest thing worn in it.
    static func forSlot(_ slot: String) -> GameIcon {
        switch slot.uppercased() {
        case "BELL": return .tinBell
        case "LANTERN": return .bullseyeLantern
        case "BAG": return .tinkersSatchel
        case "MAP_CASE": return .foldedMap
        case "KEEPSAKE": return .hagstone
        default: return .sparkles
        }
    }

    /// An icon the server named, or `fallback` when it named none this app knows.
    static func named(_ raw: String?, or fallback: GameIcon) -> GameIcon {
        raw.flatMap(GameIcon.init(rawValue:)) ?? fallback
    }

    /// A class's icon.
    static func forClass(_ id: String) -> GameIcon {
        switch id.lowercased() {
        case "explorer": return .compass
        case "wizard": return .pointyHat
        case "warrior": return .crossedSwords
        case "scribe": return .quillInk
        default: return .star
        }
    }

    /// A kind of effort: the road, new ground, height, a rune, a note.
    static func forKind(_ kind: String) -> GameIcon {
        switch kind.uppercased() {
        case "ROAD": return .road
        case "GROUND": return .treasureMap
        case "CLIMB": return .climb
        case "RUNE": return .runeStone
        case "WORD": return .note
        default: return .mystery
        }
    }

    /// A place by its kind: a discovery's category, a search result's, a stop's.
    static func forPlace(_ kind: String) -> GameIcon {
        switch kind.uppercased() {
        case "NATURE", "PARK", "GARDEN": return .oak
        case "FOREST", "WOOD": return .forest
        case "LANDMARK", "MONUMENT", "TOWER": return .tower
        case "PUB", "BAR": return .tavern
        case "CAFE", "COFFEE": return .mug
        case "FOOD", "RESTAURANT", "BAKERY": return .meal
        case "VIEWPOINT", "PEAK": return .spyglass
        case "HISTORICAL", "RUINS", "CASTLE": return .ruins
        case "CULTURAL", "ART", "GALLERY": return .palette
        case "MUSEUM": return .temple
        case "THEATRE", "THEATER", "CINEMA": return .theater
        case "TRAIL": return .trail
        case "WATER", "RIVER", "BEACH": return .river
        case "FOUNTAIN": return .fountain
        case "BRIDGE": return .bridge
        case "SHOP", "STORE", "MARKET": return .shop
        case "CYCLING", "BIKE": return .cycling
        default: return .pin
        }
    }

    /// The player, by activity.
    static func forActivity(_ activity: String) -> GameIcon {
        switch activity.uppercased() {
        case "RUN": return .run
        case "WALK", "HIKE": return .hiking
        default: return .cycling
        }
    }
}
