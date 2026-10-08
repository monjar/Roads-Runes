import CoreGraphics

/// A colour as four numbers, so a palette can be compared, stored and shared
/// across threads; `cgColor` makes the drawable one when it is needed.
public struct InkColor: Hashable, Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(hex: UInt32, alpha: CGFloat = 1) {
        red = CGFloat((hex >> 16) & 0xFF) / 255
        green = CGFloat((hex >> 8) & 0xFF) / 255
        blue = CGFloat(hex & 0xFF) / 255
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public func opacity(_ alpha: CGFloat) -> InkColor {
        InkColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// The second block of a two-block print: one colour beside the ink. `paper`
/// is for an icon on a dark ground (a button, the tab bar).
public enum Spot: String, Hashable, Sendable, CaseIterable {
    case terracotta, sage, wizard, scribe, gold, stone, paper
}

/// Paper, ink and the spot colours, passed in rather than read from a theme,
/// so the same mark prints cream-on-ink for the phone and line-on-black for the
/// Watch, and a dark palette later is a new value, not new art.
public struct InkPalette: Hashable, Sendable {
    public var paper: InkColor
    public var paperDeep: InkColor
    public var ink: InkColor
    public var inkSoft: InkColor
    public var hatch: InkColor
    public var spots: [Spot: InkColor]

    public init(paper: InkColor, paperDeep: InkColor, ink: InkColor, inkSoft: InkColor, hatch: InkColor, spots: [Spot: InkColor]) {
        self.paper = paper
        self.paperDeep = paperDeep
        self.ink = ink
        self.inkSoft = inkSoft
        self.hatch = hatch
        self.spots = spots
    }

    public func spot(_ spot: Spot) -> InkColor {
        spot == .paper ? paper : spots[spot] ?? ink
    }

    /// The phone: cream paper, near-black ink, the design system's hues
    /// (`ios/RoadsAndRunes/Components/Theme.swift`).
    public static let phone = InkPalette(
        paper: InkColor(hex: 0xF5EAD8),
        paperDeep: InkColor(hex: 0xEBDDC5),
        ink: InkColor(hex: 0x201E1D),
        inkSoft: InkColor(hex: 0x474238),
        hatch: InkColor(hex: 0xA19786),
        spots: [
            .terracotta: InkColor(hex: 0xC67139),
            .sage: InkColor(hex: 0x7A8A5E),
            .wizard: InkColor(hex: 0x6B5F8F),
            .scribe: InkColor(hex: 0x4F6B7A),
            .gold: InkColor(hex: 0xD9A621),
            .stone: InkColor(hex: 0xDCD3C4),
        ]
    )

    /// The Watch: the same art inverted, cream line on black, so it reads on an
    /// OLED face and costs little light.
    public static let watch = InkPalette(
        paper: InkColor(hex: 0x000000),
        paperDeep: InkColor(hex: 0x1C1A18),
        ink: InkColor(hex: 0xF5EAD8),
        inkSoft: InkColor(hex: 0xC0B6A5),
        hatch: InkColor(hex: 0x645C50),
        spots: [
            .terracotta: InkColor(hex: 0xF6A06B),
            .sage: InkColor(hex: 0xAEBF92),
            .wizard: InkColor(hex: 0xB9AFD9),
            .scribe: InkColor(hex: 0xA3BCC9),
            .gold: InkColor(hex: 0xE8C25A),
            .stone: InkColor(hex: 0x3A3632),
        ]
    )
}
