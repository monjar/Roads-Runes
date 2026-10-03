import CoreGraphics

/// Every plate the game prints, by family. Runes are on a 4×6 grid (they are
/// straight strokes on a stave); everything else is on 24×24, y down.
///
/// Composed creatures are a body, a feature placed at one of the body's
/// anchors, and a habitat mark underneath, so a new creature is a line of
/// server config (`sigil: {body, feature, mark}`), not new art.
public enum GlyphBook {
    // MARK: Runes

    static let runeGrid = CGSize(width: 4, height: 6)

    /// Plain Elder Futhark forms. Never doubled, never beside themselves (docs/WORLD.md).
    public static let runes: [String: String] = [
        "fehu": "M1 0V6M1 2L3 0M1 4L3 2",
        "uruz": "M1 6V0L3 2V6",
        "thurisaz": "M1 0V6M1 1.5L3 3L1 4.5",
        "ansuz": "M1 0V6M1 0L3 1.5M1 2L3 3.5",
        "raido": "M1 6V0L3 1.5L1 3L3 6",
        "kenaz": "M3 1L1 3L3 5",
        "gebo": "M.5 .5L3.5 5.5M3.5 .5L.5 5.5",
        "wunjo": "M1 6V0L3 1.5L1 3",
        "hagalaz": "M1 0V6M3 0V6M1 2.5L3 3.5",
        "nauthiz": "M2 0V6M1 2.5L3 3.5",
        "isa": "M2 0V6",
        "jera": "M2 .5L.5 2L2 3.5M2 2.5L3.5 4L2 5.5",
        "eihwaz": "M2 0V6M2 0L3.2 1.2M2 6L.8 4.8",
        "perthro": "M3 0L2 1L1 0V6L2 5L3 6",
        "algiz": "M2 6V0M.5 0L2 2.5L3.5 0",
        "sowilo": "M3 0L1 2L3 4L1 6",
        "tiwaz": "M2 6V0M.5 1.5L2 0L3.5 1.5",
        "berkano": "M1 6V0L3 1.5L1 3L3 4.5L1 6",
        "ehwaz": "M1 6V0L2 1.5L3 0V6",
        "mannaz": "M1 6V0L3 2.5M3 6V0L1 2.5",
        "laguz": "M1 6V0L3 2",
        "ingwaz": "M2 1L3.5 3L2 5L.5 3Z",
        "dagaz": "M.5 1V5L3.5 1V5Z",
        "othala": "M.5 6L3.5 2.5L2 .5L.5 2.5L3.5 6",
    ]

    /// The stone a rune is cut into.
    static let stone = "M5 3L18 2.5L20.6 6L21 18L18.4 21.5L6 21.6L3.4 18L3 6Z"
    static let stoneCrack = "M8.5 7L10.6 11.2L9.6 14.6"

    // MARK: Crests

    static let shield = "M4 3L20 3L20 12C20 17.5 16.5 20.5 12 22.5C7.5 20.5 4 17.5 4 12Z"

    public static let crests: [String: [Glyph.Layer]] = [
        // A compass star whose north-east point runs long: the way the edge moves.
        "explorer": [
            .init("M12 6.2L13.2 11L18 12.2L13.2 13.4L12 18.2L10.8 13.4L6 12.2L10.8 11Z", .fill, .paper),
            .init("M13.2 11L18.6 5.6L14.6 12", .fill, .paper),
            .init(Geometry.circle(12, 12.2, 2.0), .round(0.7), .accent, detail: true),
            .init("M5.6 18.4L7.2 16.8M8 19.6L9 18.6", .stroke(0.8), .paper, detail: true),
        ],
        // A rough standing stone (never an arched one: that is a headstone), one
        // stave cut down its face, three short rays.
        "wizard": [
            .init("M9.4 19L8.6 10.2L10 6.6L13.4 5.6L15.2 8.4L15.4 19Z", .stroke(1.4), .paper),
            .init("M12 9.4V16.6M12 11.2L13.5 9.8", .stroke(1.1), .paper),
            .init("M12 3.9V5M8.4 5L9.2 5.9M15.6 5L14.8 5.9", .stroke(0.9), .paper, detail: true),
        ],
        // A mattock upright over a single hill line, a notch cut in the slope.
        "warrior": [
            .init("M5.2 17.5Q12 9.6 18.8 17.5", .stroke(1.4), .paper),
            .init("M12 6V15.2", .stroke(1.5), .paper),
            .init("M8.2 7.8Q12 5.2 15.8 7.8", .stroke(1.4), .paper),
            .init("M15.2 13.4L16.2 12.6", .stroke(0.9), .paper, detail: true),
        ],
        // An open book, a road drawn across both pages and off the edge.
        "scribe": [
            .init("M5.5 9.5Q8.75 8 12 9.5Q15.25 8 18.5 9.5L18.5 16.5Q15.25 15 12 16.5Q8.75 15 5.5 16.5Z", .stroke(1.2), .paper),
            .init("M12 9.5V16.5", .stroke(0.9), .paper),
            .init("M6.8 14.6Q9.2 11.6 12 13Q15 14.4 19.6 10.6", .stroke(1.0), .paper),
        ],
    ]

    // MARK: Creature parts

    public struct Body: Sendable {
        public let layers: [Glyph.Layer]
        public let head: CGPoint
        public let back: CGPoint
        public let hand: CGPoint
    }

    public static let bodies: [String: Body] = [
        "shade": Body(
            layers: [
                .init("M12 3.5C9.5 3.5 8.5 5.5 8.5 7.5L6.5 18.5L17.5 18.5L15.5 7.5C15.5 5.5 14.5 3.5 12 3.5Z", .fill, .ink),
                .init("M10.2 10.5L9.2 17.6M13.8 10.5L14.8 17.6", .stroke(0.5), .paperDeep, detail: true),
            ],
            head: CGPoint(x: 12, y: 6.6), back: CGPoint(x: 12, y: 10), hand: CGPoint(x: 16.4, y: 11)
        ),
        "hulk": Body(
            layers: [
                .init("M6.5 9C6.5 6 9 4.5 12 4.5C15 4.5 17.5 6 17.5 9L19.5 12.5L18 18.5L6 18.5L4.5 12.5Z", .fill, .ink),
                .init("M8.6 10.6L7.8 17.2M15.4 10.6L16.2 17.2", .stroke(0.5), .paperDeep, detail: true),
            ],
            head: CGPoint(x: 12, y: 7.4), back: CGPoint(x: 12, y: 5.6), hand: CGPoint(x: 18.6, y: 12.5)
        ),
        "beast": Body(
            layers: [
                .init(
                    "M4.5 12C4.5 10 6.5 9 9.5 9L15 9L16.5 6L19.5 5.5L20 7.5L17.5 9.5L17.5 18.5L15.8 18.5L15.5 13.5L9.5 13.5L9 18.5L7.3 18.5L7 13.5C5.5 13.5 4.5 13 4.5 12Z",
                    .fill, .ink
                ),
                .init("M7 11.2Q10.5 10.2 14.5 11.2", .stroke(0.5), .paperDeep, detail: true),
            ],
            head: CGPoint(x: 18, y: 6.2), back: CGPoint(x: 11, y: 9), hand: CGPoint(x: 6, y: 12)
        ),
        "wyrm": Body(
            layers: [
                .init("M4 17C8 19.5 10 15 12 13C14 11 16.5 13.5 18 11C19 9.5 18.5 8 17 7.5", .round(2.6), .ink),
                .init("M15.4 6.2L20.2 5.4L19 9.2Z", .fill, .ink),
                .init("M2.8 15.4L5.2 16.4L3.4 18.6Z", .fill, .ink),
            ],
            head: CGPoint(x: 17.8, y: 6.8), back: CGPoint(x: 11.2, y: 12.4), hand: CGPoint(x: 14, y: 14)
        ),
        "armour": Body(
            layers: [
                .init("M9 3.5L15 3.5L15.5 8.8L13 9.2L13 10.2L17.5 11.2L17 18.5L7 18.5L6.5 11.2L11 10.2L11 9.2L8.5 8.8Z", .fill, .ink),
                .init("M7.6 14.2L16.4 14.2", .stroke(0.5), .paperDeep, detail: true),
            ],
            head: CGPoint(x: 12, y: 6.2), back: CGPoint(x: 12, y: 12.4), hand: CGPoint(x: 17.4, y: 13)
        ),
        "wisp": Body(
            layers: [
                .init("M12 3.5C15 6.5 17.5 10 17.5 13C17.5 16.6 15 19 12 19C9 19 6.5 16.6 6.5 13C6.5 10 9 6.5 12 3.5Z", .fill, .ink),
                .init("M12 9C13.5 11 14.5 12.5 14.5 14C14.5 15.8 13.4 17 12 17C10.6 17 9.5 15.8 9.5 14C9.5 12.5 10.5 11 12 9Z", .fill, .paperDeep, detail: true),
            ],
            head: CGPoint(x: 12, y: 7.6), back: CGPoint(x: 12, y: 6.4), hand: CGPoint(x: 16.4, y: 13)
        ),
        "bird": Body(
            layers: [
                .init("M4.5 12.5C6.5 9.5 10 8.5 13 9.5L16 7.2L19.8 8L17.2 10.2C18 12.5 17 15.2 14 16.2L13 19L12 16.3C8.8 16.3 6 15.3 4.5 12.5Z", .fill, .ink),
                .init("M7 12.6Q10 11 13.5 12.6", .stroke(0.5), .paperDeep, detail: true),
            ],
            head: CGPoint(x: 16.8, y: 7.4), back: CGPoint(x: 9.6, y: 10.6), hand: CGPoint(x: 13, y: 17)
        ),
    ]

    public enum Anchor: Sendable { case head, back, hand }

    public struct Feature: Sendable {
        public let anchor: Anchor
        /// Paths drawn about (0, 0), moved to the body's anchor.
        public let layers: [Glyph.Layer]
    }

    public static let features: [String: Feature] = [
        "antlers": Feature(anchor: .head, layers: [
            .init("M-1 -0.5L-2.6 -4.6M-1.9 -2.6L-3.9 -3.1M1 -0.5L1.8 -4.9M1.5 -2.9L3.4 -3.7", .stroke(0.9), .ink),
        ]),
        "horns": Feature(anchor: .head, layers: [
            .init("M-2.6 -0.6C-4.6 -1 -4.9 -3 -3.7 -4.3M2.6 -0.6C4.6 -1 4.9 -3 3.7 -4.3", .round(1.1), .ink),
        ]),
        "crown": Feature(anchor: .head, layers: [
            .init("M-3 -1.6L-3 -4.6L-1.5 -3.2L0 -5.2L1.5 -3.2L3 -4.6L3 -1.6Z", .fill, .accent),
            .init("M-3 -1.6L-3 -4.6L-1.5 -3.2L0 -5.2L1.5 -3.2L3 -4.6L3 -1.6Z", .stroke(0.6), .ink),
        ]),
        "hood": Feature(anchor: .head, layers: [
            .init("M-1.7 -0.3L-0.5 -0.3L-0.5 0.5L-1.7 0.5ZM0.5 -0.3L1.7 -0.3L1.7 0.5L0.5 0.5Z", .fill, .paper),
        ]),
        "hook": Feature(anchor: .hand, layers: [
            .init("M0 -4L1.6 9M0 -4C0 -6.2 2.6 -6.4 2.6 -4.2", .stroke(0.9), .ink),
        ]),
        "visor": Feature(anchor: .head, layers: [
            .init("M-2.2 -0.4L2.2 -0.4L2.2 0.5L-2.2 0.5Z", .fill, .paper),
        ]),
        "ember": Feature(anchor: .head, layers: [
            .init("M-1.9 -0.5L-0.6 -0.5L-0.6 0.6L-1.9 0.6ZM0.6 -0.5L1.9 -0.5L1.9 0.6L0.6 0.6Z", .fill, .spot(.terracotta)),
        ]),
        "wings": Feature(anchor: .back, layers: [
            .init("M0 0L-4 -6L-2 -1L-6 -4L-1.5 1.5Z", .fill, .ink),
        ]),
        "moss": Feature(anchor: .back, layers: [
            .init(
                "M-4.5 0Q-3.75 -1.7 -3 0Q-2.25 -1.7 -1.5 0Q-0.75 -1.7 0 0Q0.75 -1.7 1.5 0Q2.25 -1.7 3 0Q3.75 -1.7 4.5 0",
                .round(1.0), .spot(.sage)
            ),
        ]),
        "fins": Feature(anchor: .back, layers: [
            .init("M-3.2 0L-2.2 -3L-1.2 0ZM0.4 0.8L1.4 -2.2L2.4 0.8Z", .fill, .ink),
        ]),
    ]

    /// What a creature stands on, along the bottom of its plate.
    public static let marks: [String: [Glyph.Layer]] = [
        "water": [.init(
            "M3 20.5Q5 19.5 7 20.5Q9 21.5 11 20.5Q13 19.5 15 20.5Q17 21.5 19 20.5Q20 20 21 20.5M6 22.6Q8 21.6 10 22.6Q12 23.6 14 22.6Q16 21.6 18 22.6",
            .round(0.9), .inkSoft
        )],
        "reeds": [.init("M4 23L4.2 18.8M5.4 23L5.9 18M19 23L18.8 18.6M20.4 23L20 19.2M2.6 23L21.4 23", .stroke(0.8), .inkSoft)],
        "bridge": [.init("M2.5 23L2.5 21.5Q12 18.6 21.5 21.5L21.5 23", .round(1.0), .inkSoft)],
        "wall": [.init("M2.5 20.4L21.5 20.4M2.5 23L21.5 23M6 20.4L6 23M11 20.4L11 23M16 20.4L16 23M20 20.4L20 23", .stroke(0.8), .inkSoft)],
        "lamp": [
            .init("M21 23L21 14.6M2.5 23L21 23", .stroke(0.9), .inkSoft),
            .init("M19.6 14.6L22.4 14.6L21.9 12.4L20.1 12.4Z", .fill, .ink),
            .init("M20.5 14L21.5 14L21.4 13L20.6 13Z", .fill, .spot(.gold)),
        ],
        "ash": [
            .init("M3.5 22.2L5 22.2M7 21.4L7.9 21.4M16.8 22.2L18.2 22.2M19.6 21.4L20.5 21.4", .round(0.8), .inkSoft),
            .init("M20 18.6Q21.6 17.1 20 15.6Q18.4 14.1 20 12.6", .round(0.7), .inkSoft, detail: true),
        ],
        "mist": [.init("M2.5 20.2L8 20.2M10.5 20.2L21.5 20.2M4 22.6L14 22.6M16.5 22.6L20 22.6", .round(0.8), .inkSoft)],
        "tree": [
            .init("M4 23L4 18.5M2.4 23L21.6 23", .stroke(0.9), .inkSoft),
            .init("M4 18.5C1.2 18.5 1 14.5 4 13.5C7 14.5 6.8 18.5 4 18.5Z", .fill, .inkSoft),
        ],
    ]

    // MARK: Frames

    static let disc = Geometry.circle(12, 12, 11.4)
    static let ringOuter = Geometry.circle(12, 12, 11.4)
    static let ringInner = Geometry.circle(12, 12, 10.2)
    static let notches = Geometry.ticks(12, 12, inner: 9.8, outer: 11.4, count: 12, offset: 15)

    // MARK: Things

    public static let chests: [Int: [Glyph.Layer]] = [
        1: chest(bands: false, gilded: false),
        2: chest(bands: true, gilded: false),
        3: chest(bands: true, gilded: true),
    ]

    private static func chest(bands: Bool, gilded: Bool) -> [Glyph.Layer] {
        let body = "M4.5 11L19.5 11L19.5 19.5L4.5 19.5Z"
        let lid = "M4.5 11C4.5 6.6 19.5 6.6 19.5 11Z"
        var layers: [Glyph.Layer] = [
            .init(body, .fill, gilded ? .spot(.gold) : .spot(.stone)),
            .init(lid, .fill, gilded ? .spot(.gold) : .spot(.stone)),
            .init(body, .hatch(spacing: 1.6, weight: 0.35), .hatch, detail: true),
            .init(body, .stroke(1.3), .ink),
            .init(lid, .stroke(1.3), .ink),
            .init("M10.9 12.6L13.1 12.6L13.1 15.6L10.9 15.6Z", .fill, .ink),
        ]
        if bands {
            layers.append(.init("M8 7.4L8 19.5M16 7.4L16 19.5", .stroke(1.1), .ink))
        }
        if gilded {
            layers.append(.init("M6 17.8L6.8 17.8M17.2 17.8L18 17.8M6 12.6L6.8 12.6M17.2 12.6L18 12.6", .stroke(0.9), .ink, detail: true))
        }
        return layers
    }

    /// A long-cross penny: the cross runs to the rim, a pellet in each quarter.
    public static let coin: [Glyph.Layer] = [
        .init(Geometry.circle(12, 12, 8), .fill, .spot(.gold)),
        .init(Geometry.circle(12, 12, 8), .stroke(1.2), .ink),
        .init(Geometry.circle(12, 12, 5.9), .round(0.6), .inkSoft, detail: true),
        .init("M12 6.1L12 17.9M6.1 12L17.9 12", .stroke(0.8), .ink),
        .init(Geometry.circle(9.6, 9.6, 0.8) + Geometry.circle(14.4, 9.6, 0.8) + Geometry.circle(9.6, 14.4, 0.8) + Geometry.circle(14.4, 14.4, 0.8), .fill, .ink),
    ]

    /// A drawstring purse, tied at the neck.
    public static let purse: [Glyph.Layer] = [
        .init("M9 9.6C5 12.6 5.4 20 12 20C18.6 20 19 12.6 15 9.6L13.8 7L10.2 7Z", .fill, .spot(.stone)),
        .init("M9 9.6C5 12.6 5.4 20 12 20C18.6 20 19 12.6 15 9.6L13.8 7L10.2 7Z", .hatch(spacing: 1.6, weight: 0.3), .hatch, detail: true),
        .init("M9 9.6C5 12.6 5.4 20 12 20C18.6 20 19 12.6 15 9.6L13.8 7L10.2 7Z", .stroke(1.2), .ink),
        .init("M9.4 9.7L14.6 9.7", .stroke(1.3), .ink),
        .init("M14.6 9.7L16.8 8.2M14.6 9.7L16.4 11", .round(0.9), .ink),
    ]

    /// The five kinds of effort a thing can want: the road, new ground,
    /// height, a rune, the word.
    public static let kinds: [String: [Glyph.Layer]] = [
        "ROAD": [
            .init("M6.5 20.5L11 4.5M17.5 20.5L13 4.5", .stroke(1.3), .ink),
            .init("M12 18.6L12 16.4M12 13.4L12 11.8M12 9.4L12 8.4", .stroke(0.9), .ink),
        ],
        "GROUND": [
            .init("M15 7L20 5L20 17L15 19Z", .hatch(spacing: 1.4, weight: 0.4), .hatch),
            .init("M4 7L9 5L15 7L20 5L20 17L15 19L9 17L4 19Z", .stroke(1.2), .ink),
            .init("M9 5L9 17M15 7L15 19", .stroke(0.8), .ink),
        ],
        "CLIMB": [
            .init("M3 19.5L10 9L14 14L17 11L21 19.5Z", .fill, .spot(.stone)),
            .init("M3 19.5L10 9L14 14L17 11L21 19.5Z", .stroke(1.1), .ink),
            .init("M7.6 16.6L12.8 7.8M12.8 7.8L10.2 8.2M12.8 7.8L12.7 10.5", .stroke(1.0), .ink),
        ],
        "RUNE": [
            .init(Geometry.circle(12, 12, 8.4), .round(0.8), .inkSoft),
            .init("M10.2 17.4L10.2 6.6L13.8 9.3L10.2 12L13.8 17.4", .stroke(1.3), .ink),
        ],
        "WORD": [
            .init("M17.5 3.8C12.5 5.8 9.2 10.8 7.6 17L8.6 17.6C11.2 12 14.4 8 17.5 3.8Z", .fill, .ink),
            .init("M7.6 17L6.6 20", .stroke(0.9), .ink),
            .init("M10 20.6Q13 19.2 16 20.6Q18 21.6 20.4 20.4", .round(0.8), .inkSoft),
        ],
    ]
}
