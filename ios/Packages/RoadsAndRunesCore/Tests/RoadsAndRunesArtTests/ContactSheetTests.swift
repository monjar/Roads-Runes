import CoreGraphics
import Foundation
import ImageIO
@testable import RoadsAndRunesArt
import UniformTypeIdentifiers
import XCTest

/// Every mark, drawn to PNG without a simulator, so the art can be looked at
/// and signed off a family at a time (docs/ROADMAP.md, Ground truth 4). Set
/// ART_OUT to keep the sheets somewhere; otherwise they go to a temp folder.
final class ContactSheetTests: XCTestCase {
    static let sizes: [CGFloat] = [20, 34, 48, 96]

    static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["ART_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("rr-art").path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let sigils: [(String, Sigil)] = [
        ("bog-wraith", Sigil(body: "wisp", feature: "hood", mark: "reeds")),
        ("fen-troll", Sigil(body: "hulk", feature: "horns", mark: "water")),
        ("tide-serpent", Sigil(body: "wyrm", feature: "fins", mark: "water")),
        ("mire-hag", Sigil(body: "shade", feature: "hook", mark: "reeds")),
        ("rook-lord", Sigil(body: "bird", feature: "crown", mark: "tree")),
        ("grey-stag", Sigil(body: "beast", feature: "antlers", mark: "mist")),
        ("moss-golem", Sigil(body: "hulk", feature: "moss", mark: "wall")),
        ("hollow-sentry", Sigil(body: "armour", feature: "visor", mark: "wall")),
        ("ash-warden", Sigil(body: "armour", feature: "ember", mark: "ash")),
        ("gutter-drake", Sigil(body: "wyrm", feature: "wings", mark: "wall")),
        ("lamp-sprite", Sigil(body: "wisp", feature: "ember", mark: "lamp")),
        ("cinder-hound", Sigil(body: "beast", feature: "ember", mark: "ash")),
        // The twelve from 0.7.2 name their icon; their body and feature may repeat an older pair.
        ("hedge-dragon", Sigil(body: "wyrm", feature: "wings", mark: "tree", icon: "hedgeDragon")),
        ("hill-wyvern", Sigil(body: "wyrm", feature: "wings", mark: "mist", icon: "hillWyvern")),
        ("culvert-imp", Sigil(body: "shade", feature: "horns", mark: "water", icon: "culvertImp")),
        ("bridge-ogre", Sigil(body: "hulk", feature: "horns", mark: "water", icon: "bridgeOgre")),
        ("stile-boggart", Sigil(body: "shade", feature: "hood", mark: "tree", icon: "stileBoggart")),
        ("milestone-goblin", Sigil(body: "shade", feature: "hook", mark: "wall", icon: "milestoneGoblin")),
        ("gatehouse-gargoyle", Sigil(body: "armour", feature: "wings", mark: "wall", icon: "gatehouseGargoyle")),
        ("bramble-wolf", Sigil(body: "beast", feature: "thorns", mark: "tree", icon: "brambleWolf")),
        ("rooftop-griffin", Sigil(body: "bird", feature: "crown", mark: "wall", icon: "rooftopGriffin")),
        ("marsh-wisp", Sigil(body: "wisp", feature: "ember", mark: "reeds", icon: "marshWisp")),
        ("stone-giant", Sigil(body: "hulk", feature: "moss", mark: "wall", icon: "stoneGiant")),
        ("tavern-brownie", Sigil(body: "shade", feature: "hood", mark: "lamp", icon: "tavernBrownie")),
    ]

    static let items = ["tin-bell", "drovers-bell", "unrung-bell", "candle-stub", "bullseye-lantern", "wreckers-light",
                        "saddle-roll", "tinkers-satchel", "poachers-pocket", "folded-map", "pedlars-roadbook",
                        "cartographers-atlas", "hagstone", "rowan-twig", "runesmiths-nail"]
    static let consumables = ["LAMP", "MAP_FRAGMENT", "REST_TOKEN", "SEALED_CHEST_COMMON", "SEALED_CHEST_RARE"]
    static let slots = ["BELL", "LANTERN", "BAG", "MAP_CASE", "KEEPSAKE"]

    func testEveryPathParsesAndStaysOnItsGrid() throws {
        func check(_ source: String, grid: CGSize, _ name: String) throws {
            let path = try InkPath(source)
            XCTAssertFalse(path.elements.isEmpty, name)
            for p in path.points {
                XCTAssert(p.x >= -0.6 && p.x <= grid.width + 0.6 && p.y >= -0.6 && p.y <= grid.height + 0.6,
                          "\(name) leaves its grid at \(p)")
            }
        }
        XCTAssertEqual(GlyphBook.runes.count, 24)
        for (id, source) in GlyphBook.runes { try check(source, grid: GlyphBook.runeGrid, id) }
        let grid = CGSize(width: 24, height: 24)
        try check(GlyphBook.shield, grid: grid, "shield")
        try check(GlyphBook.disc, grid: grid, "disc")
    }

    func testTheParserReadsTheShorthandRunesUse() throws {
        let gebo = try InkPath("M.5 .5L3.5 5.5M3.5 .5L.5 5.5")
        XCTAssertEqual(gebo.points.first, CGPoint(x: 0.5, y: 0.5))
        let relative = try InkPath("m1 1l2 0v2h-2z")
        XCTAssertEqual(relative.points, [CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1), CGPoint(x: 3, y: 3), CGPoint(x: 1, y: 3)])
    }

    func testEveryCreatureHasItsOwnIcon() {
        XCTAssertEqual(Self.sigils.count, 24)
        let icons = Self.sigils.map { GameIcon.forSigil($0.1) }
        XCTAssertEqual(Set(icons).count, Self.sigils.count, "two creatures share a face")
        for (id, sigil) in Self.sigils {
            XCTAssertEqual(GameIcon.forSigil(sigil), GameIcon.forSpecies(id), id)
            XCTAssertNotEqual(GameIcon.forSpecies(id), .dragonHead, "\(id) has no face of its own")
        }
    }

    /// The server names the icon (0.7.2); a name this app does not know falls back to the pair.
    func testASigilsOwnIconWinsAndAnUnknownOneFallsBack() {
        XCTAssertEqual(GameIcon.forSigil(Sigil(body: "hulk", feature: "horns", mark: "water", icon: "bridgeOgre")), .bridgeOgre)
        XCTAssertEqual(GameIcon.forSigil(Sigil(body: "hulk", feature: "horns", mark: "water", icon: "notYetDrawn")), .troll)
        let old = try? JSONDecoder().decode(Sigil.self, from: Data(#"{"body": "wisp", "feature": "hood", "mark": "reeds"}"#.utf8))
        XCTAssertNil(old?.icon)
        XCTAssertEqual(old.map(GameIcon.forSigil), .ghost)
        XCTAssertNotEqual(Mark.creature(Sigil(body: "hulk", feature: "horns", mark: "water")).id,
                          Mark.creature(Sigil(body: "hulk", feature: "horns", mark: "water", icon: "bridgeOgre")).id,
                          "two faces must not share a cached drawing")
    }

    /// Every item, consumable and slot has its own drawing, and none is the fallback.
    func testEveryItemConsumableAndSlotHasAnIcon() {
        let items = Self.items.map(GameIcon.forItem)
        XCTAssertEqual(Set(items).count, 15, "two items share a face")
        XCTAssertFalse(items.contains(.sparkles))
        XCTAssertFalse(Self.consumables.map(GameIcon.forConsumable).contains(.sparkles))
        XCTAssertEqual(GameIcon.forConsumable("REST_TOKEN"), .restToken)
        XCTAssertFalse(Self.slots.map(GameIcon.forSlot).contains(.sparkles))
        XCTAssertEqual(GameIcon.named("hagstone", or: .sparkles), .hagstone)
        XCTAssertEqual(GameIcon.named(nil, or: .chest), .chest)
        XCTAssertEqual(Spot.forRarity("LEGENDARY"), .gold)
        XCTAssertNil(Spot.forRarity("COMMON"))
    }

    func testEveryIconParsesAndStaysOnItsGrid() throws {
        for icon in GameIcon.allCases {
            let path = try InkPath(icon.path)
            XCTAssertFalse(path.elements.isEmpty, icon.rawValue)
            // Control points may stand off the grid; the curve itself may not.
            let grid = CGRect(x: 0, y: 0, width: GameIcon.grid, height: GameIcon.grid)
            let drawn = path.cgPath(grid: grid.size, in: grid).boundingBoxOfPath
            XCTAssert(grid.insetBy(dx: -2, dy: -2).contains(drawn), "\(icon.rawValue) leaves its grid: \(drawn)")
            XCTAssertFalse(icon.author.isEmpty, icon.rawValue)
        }
    }

    func testTheContactSheetsRender() throws {
        let runes = GlyphBook.runes.keys.sorted().map { Mark.rune($0) }
        let crests = ["explorer", "wizard", "warrior", "scribe"].map { Mark.crest($0) }
        let creatures = Self.sigils.map { Mark.creature($0.1) }
        let elders = Self.sigils.prefix(4).flatMap { [Mark.creature($0.1, tier: 2), Mark.creature($0.1, tier: 3), Mark.creature($0.1, bounty: true), Mark.creature($0.1, unmet: true)] }
        let things: [Mark] = [.chest(tier: 1), .chest(tier: 2), .chest(tier: 3), .coin, .purse, .worn,
                              .quest, .objective, .mystery, .pin, .lamp, .rider("RIDE"), .rider("RUN"), .rider("WALK")]
            + ["ROAD", "GROUND", "CLIMB", "RUNE", "WORD"].map { Mark.kind($0) }
        let places = ["NATURE", "LANDMARK", "PUB", "CAFE", "FOOD", "VIEWPOINT", "HISTORICAL", "CULTURAL", "MUSEUM",
                      "TRAIL", "WATER", "BRIDGE", "SHOP", "CYCLING", "SOMEWHERE"].map { Mark.place($0) }
        let icons = GameIcon.allCases.map { Mark.icon($0) }
        // 0.7.2: the fifteen items in their three rarities, the consumables and the empty slots.
        let rarities = ["COMMON", "RARE", "LEGENDARY"]
        let gear = Self.items.enumerated().map { Mark.item(GameIcon.forItem($0.element), rarity: rarities[$0.offset % 3]) }
            + Self.consumables.map { Mark.item(GameIcon.forConsumable($0), rarity: $0.hasSuffix("RARE") ? "RARE" : nil) }
            + Self.slots.map { Mark.icon(GameIcon.forSlot($0)) }
        for (name, marks) in [("runes", runes), ("crests", crests), ("creatures", creatures), ("elders", elders), ("things", things),
                               ("places", places), ("icons", icons), ("gear", gear)] {
            for (paletteName, palette) in [("phone", InkPalette.phone), ("watch", InkPalette.watch)] {
                let url = Self.outputDirectory.appendingPathComponent("\(name)-\(paletteName).png")
                try Self.sheet(marks, palette: palette, to: url)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    /// One row per mark, one column per size, at 2× so the small sizes can be judged.
    static func sheet(_ marks: [Mark], palette: InkPalette, to url: URL) throws {
        let scale: CGFloat = 2
        let gap: CGFloat = 12
        let cell = sizes.max()! + gap
        let width = (CGFloat(sizes.count) * cell + gap) * scale
        let height = (CGFloat(marks.count) * cell + gap) * scale
        guard let ctx = CGContext(
            data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "art", code: 1) }
        ctx.setFillColor(palette.paperDeep.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        for (row, mark) in marks.enumerated() {
            for (column, size) in sizes.enumerated() {
                let x = gap + CGFloat(column) * cell + (sizes.max()! - size) / 2
                let y = gap + CGFloat(row) * cell + (sizes.max()! - size) / 2
                MarkRenderer.drawFlipped(mark, in: ctx, rect: CGRect(x: x, y: y, width: size, height: size),
                                         canvasHeight: height / scale, palette: palette)
            }
        }
        guard let image = ctx.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw NSError(domain: "art", code: 2) }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
