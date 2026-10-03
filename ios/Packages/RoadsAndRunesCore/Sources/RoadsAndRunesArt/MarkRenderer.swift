import CoreGraphics
import Foundation

/// Draws a mark into a CoreGraphics context. Everything that shows a mark goes
/// through here: SwiftUI views (through `GraphicsContext.withCGContext`), the
/// UIKit map annotations (rendered once into an image) and the contact-sheet
/// test that writes every mark to a PNG. One drawing, so they cannot differ.
///
/// The context must be y-down (as SwiftUI's is). `drawFlipped` sets that up
/// for a plain bitmap context.
public enum MarkRenderer {
    /// Below this size a mark drops its hatching and fine detail and is drawn
    /// as a silhouette: map markers, the Watch's Always-On face, complications.
    public static let detailSize: CGFloat = 28

    public static func draw(_ mark: Mark, in ctx: CGContext, rect: CGRect, palette: InkPalette) {
        let detailed = min(rect.width, rect.height) >= detailSize
        let wobble = Wobble(id: mark.id, amount: 0.12)
        let painter = Painter(ctx: ctx, palette: palette, detailed: detailed)
        switch mark {
        case let .rune(id):
            guard let source = GlyphBook.runes[id.lowercased()] else {
                drawWorn(painter, rect: rect, wobble: wobble)
                return
            }
            painter.layers(stoneLayers, grid: grid24, in: rect, wobble: wobble)
            let inner = runeRect(in: rect)
            painter.layers(
                [Glyph.Layer(source, .stroke(0.52), .ink)],
                grid: GlyphBook.runeGrid, in: inner, wobble: Wobble(id: mark.id, amount: 0.03)
            )
        case let .crest(id):
            let accent = painter.palette.spot(Mark.spot(forCrest: id))
            painter.layers([Glyph.Layer(GlyphBook.shield, .fill, .accent)], grid: grid24, in: rect, wobble: wobble, accent: accent)
            if let motif = GlyphBook.crests[id.lowercased()] {
                painter.layers(motif, grid: grid24, in: rect, wobble: wobble, accent: accent)
            }
            painter.layers([Glyph.Layer(GlyphBook.shield, .stroke(1.4), .ink)], grid: grid24, in: rect, wobble: wobble)
        case let .creature(sigil, tier, bounty, unmet):
            drawCreature(painter, sigil: sigil, tier: tier, bounty: bounty, unmet: unmet, rect: rect, wobble: wobble)
        case let .chest(tier):
            painter.layers(GlyphBook.chests[max(1, min(3, tier))] ?? [], grid: grid24, in: rect, wobble: wobble)
        case .coin:
            painter.layers(GlyphBook.coin, grid: grid24, in: rect, wobble: wobble)
        case .purse:
            painter.layers(GlyphBook.purse, grid: grid24, in: rect, wobble: wobble)
        case let .kind(kind):
            guard let layers = GlyphBook.kinds[kind.uppercased()] else {
                drawWorn(painter, rect: rect, wobble: wobble)
                return
            }
            painter.layers(layers, grid: grid24, in: rect, wobble: wobble)
        case .worn:
            drawWorn(painter, rect: rect, wobble: wobble)
        }
    }

    /// For a bitmap context (y up): flips it, draws, and puts it back.
    public static func drawFlipped(_ mark: Mark, in ctx: CGContext, rect: CGRect, canvasHeight: CGFloat, palette: InkPalette) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvasHeight)
        ctx.scaleBy(x: 1, y: -1)
        draw(mark, in: ctx, rect: rect, palette: palette)
        ctx.restoreGState()
    }

    // MARK: - Pieces

    static let grid24 = CGSize(width: 24, height: 24)

    static var stoneLayers: [Glyph.Layer] {
        [
            Glyph.Layer(GlyphBook.stone, .fill, .spot(.stone)),
            Glyph.Layer(GlyphBook.stone, .hatch(spacing: 1.8, weight: 0.3), .hatch, detail: true),
            Glyph.Layer(GlyphBook.stone, .stroke(0.9), .ink),
        ]
    }

    static func runeRect(in rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 0.27, dy: rect.height * 0.2)
    }

    private static func drawWorn(_ painter: Painter, rect: CGRect, wobble: Wobble) {
        painter.layers(stoneLayers + [Glyph.Layer(GlyphBook.stoneCrack, .stroke(0.8), .inkSoft)], grid: grid24, in: rect, wobble: wobble)
    }

    private static func drawCreature(
        _ painter: Painter, sigil: Sigil, tier: Int, bounty: Bool, unmet: Bool, rect: CGRect, wobble: Wobble
    ) {
        let gold = painter.palette.spot(.gold)
        let ringInk: Glyph.Ink = bounty ? .spot(.gold) : .ink
        painter.layers([Glyph.Layer(GlyphBook.disc, .fill, .paper)], grid: grid24, in: rect, wobble: nil)
        guard let body = GlyphBook.bodies[sigil.body] else {
            painter.layers(stoneLayers, grid: grid24, in: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2), wobble: wobble)
            painter.layers([Glyph.Layer(GlyphBook.ringOuter, .round(1.0), ringInk)], grid: grid24, in: rect, wobble: nil)
            return
        }
        let inner = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16)
        if let mark = GlyphBook.marks[sigil.mark] {
            painter.layers(mark, grid: grid24, in: inner, wobble: wobble)
        }
        painter.layers(body.layers, grid: grid24, in: inner, wobble: wobble)
        if !unmet, let feature = GlyphBook.features[sigil.feature] {
            let at: CGPoint
            switch feature.anchor {
            case .head: at = body.head
            case .back: at = body.back
            case .hand: at = body.hand
            }
            painter.layers(feature.layers, grid: grid24, in: inner, wobble: wobble, accent: gold, offset: at)
        }
        painter.layers([Glyph.Layer(GlyphBook.ringOuter, .round(bounty ? 1.5 : 1.0), ringInk)], grid: grid24, in: rect, wobble: nil)
        if tier >= 2 {
            painter.layers([Glyph.Layer(GlyphBook.ringInner, .round(0.6), ringInk)], grid: grid24, in: rect, wobble: nil)
        }
        if tier >= 3 {
            painter.layers([Glyph.Layer(GlyphBook.notches, .stroke(0.8), ringInk)], grid: grid24, in: rect, wobble: nil)
        }
    }
}

/// Inks layers onto the context. Paths are parsed once and kept.
struct Painter {
    let ctx: CGContext
    let palette: InkPalette
    let detailed: Bool

    func layers(
        _ layers: [Glyph.Layer], grid: CGSize, in rect: CGRect, wobble: Wobble?,
        accent: InkColor? = nil, offset: CGPoint = .zero
    ) {
        let scale = min(rect.width / grid.width, rect.height / grid.height)
        for layer in layers where detailed || !layer.detail {
            guard var path = PathCache.shared.path(layer.source) else { continue }
            if offset != .zero { path = path.translated(by: offset) }
            let cg = path.cgPath(grid: grid, in: rect, wobble: wobble)
            let color = resolve(layer.ink, accent: accent).cgColor
            ctx.saveGState()
            switch layer.style {
            case let .stroke(weight), let .round(weight):
                ctx.setStrokeColor(color)
                ctx.setLineWidth(max(0.6, weight * scale))
                if case .round = layer.style {
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                } else {
                    ctx.setLineCap(.butt)
                    ctx.setLineJoin(.miter)
                    ctx.setMiterLimit(3)
                }
                ctx.addPath(cg)
                ctx.strokePath()
            case .fill:
                ctx.setFillColor(color)
                // The second block of a two-block print sits a hair off the first.
                if detailed, isSpot(layer.ink) { ctx.translateBy(x: scale * 0.12, y: scale * 0.12) }
                ctx.addPath(cg)
                ctx.fillPath(using: .evenOdd)
            case let .hatch(spacing, weight):
                ctx.addPath(cg)
                ctx.clip(using: .evenOdd)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(max(0.4, weight * scale))
                let bounds = cg.boundingBoxOfPath
                let step = max(1.5, spacing * scale)
                var x = bounds.minX - bounds.height
                while x < bounds.maxX {
                    ctx.move(to: CGPoint(x: x, y: bounds.maxY))
                    ctx.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
                    x += step
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
    }

    private func isSpot(_ ink: Glyph.Ink) -> Bool {
        switch ink {
        case .spot, .accent: return true
        default: return false
        }
    }

    func resolve(_ ink: Glyph.Ink, accent: InkColor?) -> InkColor {
        switch ink {
        case .ink: return palette.ink
        case .inkSoft: return palette.inkSoft
        case .paper: return palette.paper
        case .paperDeep: return palette.paperDeep
        case .hatch: return palette.hatch
        case let .spot(spot): return palette.spot(spot)
        case .accent: return accent ?? palette.ink
        }
    }
}

/// Parsed paths, kept: a mark is drawn many times and its text never changes.
final class PathCache: @unchecked Sendable {
    static let shared = PathCache()
    private var store: [String: InkPath] = [:]
    private let lock = NSLock()

    func path(_ source: String) -> InkPath? {
        lock.lock()
        defer { lock.unlock() }
        if let found = store[source] { return found }
        guard let parsed = try? InkPath(source) else { return nil }
        store[source] = parsed
        return parsed
    }
}

extension InkPath {
    func translated(by offset: CGPoint) -> InkPath {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.x, y: p.y + offset.y) }
        return InkPath(elements: elements.map { element in
            switch element {
            case let .move(p): return .move(t(p))
            case let .line(p): return .line(t(p))
            case let .quad(p, c): return .quad(t(p), control: t(c))
            case let .cubic(p, c1, c2): return .cubic(t(p), control1: t(c1), control2: t(c2))
            case .close: return .close
            }
        })
    }
}

public extension MarkRenderer {
    /// The mark as a bitmap, for UIKit (map annotations) and anything else that
    /// wants an image. `scale` is the screen's.
    static func cgImage(_ mark: Mark, size: CGFloat, scale: CGFloat, palette: InkPalette) -> CGImage? {
        let pixels = Int((size * scale).rounded(.up))
        guard pixels > 0, let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        drawFlipped(mark, in: ctx, rect: CGRect(x: 0, y: 0, width: size, height: size), canvasHeight: size, palette: palette)
        return ctx.makeImage()
    }
}
