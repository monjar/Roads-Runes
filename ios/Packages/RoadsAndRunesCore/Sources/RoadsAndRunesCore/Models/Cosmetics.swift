import Foundation

// Looks you can buy (0.9.0): a route ink, a marker frame for the rider on the map,
// and a frame for the crest. They are items in the bag with ids prefixed `ink:`,
// `marker:` and `crest:`; what is worn is the inventory's `look`.

/// The three kinds of look, by the prefix of their item ids.
public enum CosmeticKind: String, CaseIterable, Sendable {
    case ink = "INK"
    case markerFrame = "MARKER_FRAME"
    case crestFrame = "CREST_FRAME"

    /// `ink:`, `marker:`, `crest:`.
    public var prefix: String {
        switch self {
        case .ink: return "ink"
        case .markerFrame: return "marker"
        case .crestFrame: return "crest"
        }
    }

    /// "Route ink", "Marker frame", "Crest frame".
    public var name: String {
        switch self {
        case .ink: return "Route ink"
        case .markerFrame: return "Marker frame"
        case .crestFrame: return "Crest frame"
        }
    }

    /// The kind an item id or a server's kind word names, if any.
    public static func of(itemId: String?, kind: String? = nil) -> CosmeticKind? {
        if let kind = kind?.uppercased() {
            switch kind {
            case "INK", "ROUTE_INK": return .ink
            case "MARKER", "MARKER_FRAME", "MARKERFRAME": return .markerFrame
            case "CREST", "CREST_FRAME", "CRESTFRAME": return .crestFrame
            default: break
            }
        }
        guard let itemId, let colon = itemId.firstIndex(of: ":") else { return nil }
        let prefix = itemId[..<colon].lowercased()
        return allCases.first { $0.prefix == prefix }
    }

    /// "sage" from "ink:sage"; an id with no prefix stays as it is.
    public static func bareId(_ itemId: String) -> String {
        guard let colon = itemId.firstIndex(of: ":") else { return itemId }
        return String(itemId[itemId.index(after: colon)...])
    }
}

/// What is worn: the ink, the marker frame, the crest frame (`InventoryOut.look`).
/// Each is an item id ("ink:sage") or a bare one ("sage"); nil is the plain one.
public struct Look: Codable, Hashable, Sendable {
    public var ink: String?
    public var markerFrame: String?
    public var crestFrame: String?

    public init(ink: String? = nil, markerFrame: String? = nil, crestFrame: String? = nil) {
        self.ink = ink
        self.markerFrame = markerFrame
        self.crestFrame = crestFrame
    }

    public static let plain = Look()

    public func value(_ kind: CosmeticKind) -> String? {
        switch kind {
        case .ink: return ink
        case .markerFrame: return markerFrame
        case .crestFrame: return crestFrame
        }
    }

    /// This look with one kind changed.
    public func with(_ kind: CosmeticKind, _ id: String?) -> Look {
        var out = self
        switch kind {
        case .ink: out.ink = id
        case .markerFrame: out.markerFrame = id
        case .crestFrame: out.crestFrame = id
        }
        return out
    }

    /// Whether this item id is the one worn for its kind (a bare id matches a prefixed one).
    public func wears(_ itemId: String, as kind: CosmeticKind) -> Bool {
        guard let worn = value(kind) else { return false }
        return CosmeticKind.bareId(worn) == CosmeticKind.bareId(itemId)
    }
}

/// `PUT /inventory/look`: what to wear; a field left out stays as it is.
public struct LookChoice: Codable, Hashable, Sendable {
    public var ink: String?
    public var markerFrame: String?
    public var crestFrame: String?

    public init(ink: String? = nil, markerFrame: String? = nil, crestFrame: String? = nil) {
        self.ink = ink
        self.markerFrame = markerFrame
        self.crestFrame = crestFrame
    }

    /// Wear one item of its kind.
    public init(_ kind: CosmeticKind, _ itemId: String) {
        self.init()
        switch kind {
        case .ink: ink = itemId
        case .markerFrame: markerFrame = itemId
        case .crestFrame: crestFrame = itemId
        }
    }
}

/// A look the player owns (`InventoryOut.cosmetics[]`): an ink, a marker frame or a
/// crest frame, from the stall or (a crest frame) from a deed reached.
public struct Cosmetic: Codable, Hashable, Identifiable, Sendable {
    /// "ink:sage", "marker:rope", "crest:legs-3".
    public var itemId: String
    /// INK, MARKER_FRAME or CREST_FRAME.
    public var kind: String?
    /// "Sage", "Rope frame".
    public var name: String
    /// An ink's colour, "#7A8A5E", when the server sends it.
    public var color: String?
    public var text: String?
    /// STALL or DEED.
    public var source: String?

    public var id: String { itemId }

    public init(itemId: String, kind: String? = nil, name: String? = nil, color: String? = nil, text: String? = nil, source: String? = nil) {
        self.itemId = itemId
        self.kind = kind ?? CosmeticKind.of(itemId: itemId)?.rawValue
        self.name = name ?? CosmeticCatalog.name(itemId)
        self.color = color
        self.text = text
        self.source = source
    }

    public var cosmeticKind: CosmeticKind? { CosmeticKind.of(itemId: itemId, kind: kind) }

    private enum CodingKeys: String, CodingKey { case itemId, id, kind, name, color, text, source }

    /// A plain item id, or an object with one.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let itemId = try? single.decode(String.self) {
            self.init(itemId: itemId)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let itemId = (try? c.decodeIfPresent(String.self, forKey: .itemId)) ?? (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        self.init(itemId: itemId,
                  kind: (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil,
                  name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil,
                  color: (try? c.decodeIfPresent(String.self, forKey: .color)) ?? nil,
                  text: (try? c.decodeIfPresent(String.self, forKey: .text)) ?? nil,
                  source: (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(itemId, forKey: .itemId)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

/// The looks the app knows how to draw, by bare id, and their plain names; a look
/// the app does not know yet draws as the plain one.
public enum CosmeticCatalog {
    /// The six route inks and their colours (0xRRGGBB), as `inventory/config/cosmetics.json`
    /// has them; the server's `color` wins. Everyone has Ink; with no look at all (an
    /// older server) the route stays terracotta.
    public static let inks: [(id: String, name: String, hex: UInt32)] = [
        ("ink", "Ink", 0x2E2A24),
        ("terracotta", "Terracotta", 0xB5583A),
        ("sage", "Sage", 0x7A8A5E),
        ("gold", "Gold", 0xC49A2C),
        ("wizard-blue", "Wizard Blue", 0x3D5A99),
        ("scribe-plum", "Scribe Plum", 0x6B3F69),
    ]
    /// The looks everyone has, worn until another is chosen.
    public static let plainInk = "ink"
    public static let plainMarkerFrame = "plain"
    public static let plainCrestFrame = "plain"

    /// The four marker frames.
    public static let markerFrames: [(id: String, name: String)] = [
        ("plain", "Plain"), ("rope", "Rope"), ("laurel", "Laurel"), ("runic", "Runic"),
    ]

    /// An ink's colour from its id ("ink:sage", "sage", "wizard_blue") or a "#RRGGBB" the
    /// server sent; nil for one the app does not know.
    public static func inkHex(_ id: String?, color: String? = nil) -> UInt32? {
        if let color, let hex = parseHex(color) { return hex }
        guard let id else { return nil }
        let bare = normalise(CosmeticKind.bareId(id))
        return inks.first { normalise($0.id) == bare }?.hex
    }

    /// "#7A8A5E" or "7A8A5E" as a number.
    public static func parseHex(_ text: String) -> UInt32? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    /// "Wizard Blue" from "ink:wizard-blue", "Rope" from "marker:rope", "Legs III" style names stay the server's.
    public static func name(_ itemId: String) -> String {
        let bare = CosmeticKind.bareId(itemId)
        if let ink = inks.first(where: { normalise($0.id) == normalise(bare) }) { return ink.name }
        if let frame = markerFrames.first(where: { $0.id == normalise(bare) }) { return frame.name }
        return bare.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func normalise(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
    }
}
