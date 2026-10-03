import CoreGraphics
import Foundation

/// One plate of a woodcut: a few paths on a grid, each inked one way.
public struct Glyph: Sendable {
    public enum Ink: Hashable, Sendable {
        case ink, inkSoft, paper, paperDeep, hatch
        case spot(Spot)
        /// The mark's own colour: a crest's trade, a bounty's gold.
        case accent
    }

    public enum Style: Hashable, Sendable {
        /// A line `weight` grid units wide, with square ends.
        case stroke(CGFloat)
        /// A rounded line, for things that are not cut: rings, smoke, water.
        case round(CGFloat)
        case fill
        /// Parallel lines `spacing` apart at 45°, clipped to the path.
        case hatch(spacing: CGFloat, weight: CGFloat)
    }

    public struct Layer: Sendable {
        public let source: String
        public let style: Style
        public let ink: Ink
        /// Left out when the mark is drawn small (under 28 pt): hatching and
        /// fine detail turn to mud there, and the silhouette is what reads.
        public let detail: Bool

        public init(_ source: String, _ style: Style, _ ink: Ink, detail: Bool = false) {
            self.source = source
            self.style = style
            self.ink = ink
            self.detail = detail
        }
    }

    public let id: String
    public let grid: CGSize
    public let layers: [Layer]

    public init(_ id: String, grid: CGSize = CGSize(width: 24, height: 24), _ layers: [Layer]) {
        self.id = id
        self.grid = grid
        self.layers = layers
    }
}

/// Paths built from geometry rather than typed out: circles and arcs.
enum Geometry {
    /// An arc as cubic curves, angles in degrees, 0 = east, clockwise (y down).
    static func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from start: CGFloat, to end: CGFloat, move: Bool = true) -> String {
        let segments = max(1, Int((abs(end - start) / 90).rounded(.up)))
        let step = (end - start) / CGFloat(segments)
        var out = ""
        func pt(_ deg: CGFloat) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
        }
        let first = pt(start)
        out += move ? "M\(f(first.x)) \(f(first.y))" : "L\(f(first.x)) \(f(first.y))"
        for i in 0 ..< segments {
            let a0 = (start + step * CGFloat(i)) * .pi / 180
            let a1 = (start + step * CGFloat(i + 1)) * .pi / 180
            let k = 4.0 / 3.0 * tan((a1 - a0) / 4)
            let p0 = CGPoint(x: cx + r * cos(a0), y: cy + r * sin(a0))
            let p1 = CGPoint(x: cx + r * cos(a1), y: cy + r * sin(a1))
            let c1 = CGPoint(x: p0.x - k * r * sin(a0), y: p0.y + k * r * cos(a0))
            let c2 = CGPoint(x: p1.x + k * r * sin(a1), y: p1.y - k * r * cos(a1))
            out += "C\(f(c1.x)) \(f(c1.y)) \(f(c2.x)) \(f(c2.y)) \(f(p1.x)) \(f(p1.y))"
        }
        return out
    }

    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> String {
        arc(cx, cy, r, from: 0, to: 360) + "Z"
    }

    /// Short radial ticks round a circle: the notched frame of an elder.
    static func ticks(_ cx: CGFloat, _ cy: CGFloat, inner: CGFloat, outer: CGFloat, count: Int, offset: CGFloat = 0) -> String {
        (0 ..< count).map { i -> String in
            let a = (offset + CGFloat(i) * 360 / CGFloat(count)) * .pi / 180
            return "M\(f(cx + inner * cos(a))) \(f(cy + inner * sin(a)))L\(f(cx + outer * cos(a))) \(f(cy + outer * sin(a)))"
        }.joined()
    }

    private static func f(_ v: CGFloat) -> String {
        String(format: "%.2f", Double(v))
    }
}
