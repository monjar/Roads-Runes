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
    ]

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
        for (id, layers) in GlyphBook.crests { for l in layers { try check(l.source, grid: grid, id) } }
        for (id, body) in GlyphBook.bodies { for l in body.layers { try check(l.source, grid: grid, id) } }
        for (id, layers) in GlyphBook.marks { for l in layers { try check(l.source, grid: grid, id) } }
        for (id, layers) in GlyphBook.kinds { for l in layers { try check(l.source, grid: grid, id) } }
        for (tier, layers) in GlyphBook.chests { for l in layers { try check(l.source, grid: grid, "chest \(tier)") } }
        // Features are drawn about an anchor, so they may go negative.
        for (id, feature) in GlyphBook.features {
            for l in feature.layers { XCTAssertNoThrow(try InkPath(l.source), id) }
        }
    }

    func testTheParserReadsTheShorthandRunesUse() throws {
        let gebo = try InkPath("M.5 .5L3.5 5.5M3.5 .5L.5 5.5")
        XCTAssertEqual(gebo.points.first, CGPoint(x: 0.5, y: 0.5))
        let relative = try InkPath("m1 1l2 0v2h-2z")
        XCTAssertEqual(relative.points, [CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1), CGPoint(x: 3, y: 3), CGPoint(x: 1, y: 3)])
    }

    func testEveryCreatureNamesPartsThatExist() {
        for (id, sigil) in Self.sigils {
            XCTAssertNotNil(GlyphBook.bodies[sigil.body], id)
            XCTAssertNotNil(GlyphBook.features[sigil.feature], id)
            XCTAssertNotNil(GlyphBook.marks[sigil.mark], id)
        }
    }

    func testTheContactSheetsRender() throws {
        let runes = GlyphBook.runes.keys.sorted().map { Mark.rune($0) }
        let crests = ["explorer", "wizard", "warrior", "scribe"].map { Mark.crest($0) }
        let creatures = Self.sigils.map { Mark.creature($0.1) }
        let elders = Self.sigils.prefix(4).flatMap { [Mark.creature($0.1, tier: 2), Mark.creature($0.1, tier: 3), Mark.creature($0.1, bounty: true), Mark.creature($0.1, unmet: true)] }
        let things: [Mark] = [.chest(tier: 1), .chest(tier: 2), .chest(tier: 3), .coin, .purse, .worn]
            + ["ROAD", "GROUND", "CLIMB", "RUNE", "WORD"].map { Mark.kind($0) }
        for (name, marks) in [("runes", runes), ("crests", crests), ("creatures", creatures), ("elders", elders), ("things", things)] {
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
