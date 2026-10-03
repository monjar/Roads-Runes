import CoreGraphics
import Foundation

/// A creature's face, as the server describes it: a body, a feature and what
/// it stands on (`world_objects.json`, `sigil`).
public struct Sigil: Hashable, Sendable, Codable {
    public let body: String
    public let feature: String
    public let mark: String

    public init(body: String, feature: String, mark: String) {
        self.body = body
        self.feature = feature
        self.mark = mark
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
    /// The fallback for anything the app has no drawing for yet.
    case worn

    /// A stable id for caching and for the seeded wobble.
    public var id: String {
        switch self {
        case let .rune(id): return "rune:\(id)"
        case let .crest(id): return "crest:\(id)"
        case let .creature(sigil, tier, bounty, unmet):
            return "creature:\(sigil.body)/\(sigil.feature)/\(sigil.mark)/\(tier)/\(bounty)/\(unmet)"
        case let .chest(tier): return "chest:\(tier)"
        case .coin: return "coin"
        case .purse: return "purse"
        case let .kind(kind): return "kind:\(kind)"
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
