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
        let painter = Painter(ctx: ctx, palette: palette, detailed: detailed)
        switch mark {
        case let .rune(id):
            token(painter, rect: rect, ring: palette.ink)
            guard let source = GlyphBook.runes[id.lowercased()] else {
                icon(painter, .mystery, in: iconRect(rect), color: palette.ink)
                return
            }
            painter.layers(
                [Glyph.Layer(source, .stroke(0.62), .ink)],
                grid: GlyphBook.runeGrid, in: runeRect(in: rect), wobble: nil
            )
        case let .crest(id):
            let accent = painter.palette.spot(Mark.spot(forCrest: id))
            painter.layers([Glyph.Layer(GlyphBook.shield, .fill, .accent)], grid: grid24, in: rect, wobble: nil, accent: accent)
            painter.layers([Glyph.Layer(GlyphBook.shield, .stroke(1.2), .ink)], grid: grid24, in: rect, wobble: nil)
            let inner = CGRect(x: rect.minX + rect.width * 0.27, y: rect.minY + rect.height * 0.2,
                               width: rect.width * 0.46, height: rect.height * 0.46)
            icon(painter, .forClass(id), in: inner, color: palette.paper)
        case let .creature(sigil, tier, bounty, unmet):
            creature(painter, icon: .forSigil(sigil), tier: tier, bounty: bounty, unmet: unmet, rect: rect)
        case let .chest(tier):
            let gilded = tier >= 3
            token(painter, rect: rect, ring: gilded ? palette.spot(.gold) : palette.ink, weight: gilded ? 1.5 : 1.0,
                  inner: tier == 2)
            icon(painter, .chest, in: iconRect(rect), color: palette.ink)
        case .coin:
            painter.layers([Glyph.Layer(GlyphBook.disc, .fill, .spot(.gold))], grid: grid24, in: rect, wobble: nil)
            icon(painter, .coins, in: rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2), color: palette.ink)
        case .purse:
            icon(painter, .purse, in: rect, color: palette.ink)
        case let .kind(kind):
            icon(painter, .forKind(kind), in: rect, color: palette.ink)
        case let .place(kind):
            token(painter, rect: rect, ring: palette.ink)
            icon(painter, .forPlace(kind), in: iconRect(rect), color: palette.ink)
        case let .rider(activity):
            let fill = palette.spot(.terracotta)
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: discRect(rect))
            ctx.setStrokeColor(palette.paper.cgColor)
            ctx.setLineWidth(max(1, rect.width / 14))
            ctx.strokeEllipse(in: discRect(rect).insetBy(dx: rect.width / 28, dy: rect.width / 28))
            icon(painter, .forActivity(activity), in: iconRect(rect), color: palette.paper)
        case let .token(glyph, ring):
            token(painter, rect: rect, ring: ring.map(palette.spot) ?? palette.ink, weight: ring == .gold ? 1.5 : 1.0)
            icon(painter, glyph, in: iconRect(rect), color: palette.ink)
        case let .icon(glyph, spot):
            icon(painter, glyph, in: rect, color: spot.map(palette.spot) ?? palette.ink)
        case .worn:
            token(painter, rect: rect, ring: palette.inkSoft)
            icon(painter, .mystery, in: iconRect(rect), color: palette.inkSoft)
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

    static func runeRect(in rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.26)
    }

    /// The disc of a token, a hair inside the rect so its ring is not clipped.
    static func discRect(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 0.025, dy: rect.height * 0.025)
    }

    /// Where an icon sits on a token.
    static func iconRect(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
    }

    /// A thing in the world: paper, an ink ring (gold for a bounty or a gilded
    /// chest), a second ring inside it for something a step up.
    static func token(_ painter: Painter, rect: CGRect, ring: InkColor, weight: CGFloat = 1.0, inner: Bool = false) {
        painter.layers([Glyph.Layer(GlyphBook.disc, .fill, .paper)], grid: grid24, in: rect, wobble: nil)
        let ctx = painter.ctx
        let scale = rect.width / 24
        ctx.saveGState()
        ctx.setStrokeColor(ring.cgColor)
        ctx.setLineWidth(max(0.8, weight * scale))
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.6 * scale + weight * scale / 2, dy: 0.6 * scale + weight * scale / 2))
        if inner {
            ctx.setLineWidth(max(0.5, 0.6 * scale))
            ctx.strokeEllipse(in: rect.insetBy(dx: 2.2 * scale, dy: 2.2 * scale))
        }
        ctx.restoreGState()
    }

    /// An icon filled in one colour.
    static func icon(_ painter: Painter, _ glyph: GameIcon, in rect: CGRect, color: InkColor) {
        guard let path = PathCache.shared.path(glyph.path) else { return }
        let ctx = painter.ctx
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path.cgPath(grid: CGSize(width: GameIcon.grid, height: GameIcon.grid), in: rect))
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// A creature on its token: gold-ringed for a bounty, a second ring for an
    /// elder and a crown over the top one; an unmet one only as a pale shape.
    private static func creature(_ painter: Painter, icon glyph: GameIcon, tier: Int, bounty: Bool, unmet: Bool, rect: CGRect) {
        let palette = painter.palette
        token(painter, rect: rect, ring: bounty ? palette.spot(.gold) : palette.ink, weight: bounty ? 1.6 : 1.0, inner: tier >= 2)
        icon(painter, glyph, in: iconRect(rect), color: unmet ? palette.hatch : palette.ink)
        if tier >= 3 {
            let crown = CGRect(x: rect.midX - rect.width * 0.17, y: rect.minY - rect.height * 0.04,
                               width: rect.width * 0.34, height: rect.height * 0.34)
            icon(painter, .crown, in: crown, color: palette.spot(.gold))
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
