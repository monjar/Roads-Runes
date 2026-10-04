import CoreGraphics

/// The shapes the game draws itself. Runes are on a 4×6 grid (they are straight
/// strokes on a stave); the rest on 24×24, y down. Creatures, chests, places and
/// the rest are icons from game-icons.net (`GameIcon`).
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

    // MARK: Frames

    /// A class's shield, its field in the class's colour.
    static let shield = "M4 3L20 3L20 12C20 17.5 16.5 20.5 12 22.5C7.5 20.5 4 17.5 4 12Z"
    /// The paper of a token.
    static let disc = Geometry.circle(12, 12, 11.4)
}
