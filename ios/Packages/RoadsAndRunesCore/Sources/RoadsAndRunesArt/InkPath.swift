import CoreGraphics
import Foundation

/// A path written the way SVG writes one, on a small grid: `M L H V Q C Z`, in
/// absolute or relative (lower-case) form. Every mark in the game is a handful
/// of these, so a rune or a creature is a line of text that can be read,
/// diffed and checked, and drawn at any size.
public struct InkPath: Hashable, Sendable {
    public enum Element: Hashable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, control: CGPoint)
        case cubic(CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    public let elements: [Element]

    public init(_ source: String) throws {
        elements = try InkPath.parse(source)
    }

    init(elements: [Element]) {
        self.elements = elements
    }

    public enum ParseError: Error, Equatable {
        case unexpected(String)
        case missingNumbers(Character)
    }

    /// Every point the path visits, control points included.
    public var points: [CGPoint] {
        elements.flatMap { element -> [CGPoint] in
            switch element {
            case let .move(p), let .line(p): return [p]
            case let .quad(p, c): return [c, p]
            case let .cubic(p, c1, c2): return [c1, c2, p]
            case .close: return []
            }
        }
    }

    /// The path in a rect: grid units scaled uniformly and centred, with an
    /// optional seeded wobble of each point, so a stroke looks cut by hand and
    /// is cut the same way every time it is drawn.
    public func cgPath(grid: CGSize, in rect: CGRect, wobble: Wobble? = nil) -> CGPath {
        let scale = min(rect.width / grid.width, rect.height / grid.height)
        let origin = CGPoint(
            x: rect.midX - grid.width * scale / 2,
            y: rect.midY - grid.height * scale / 2
        )
        var index = 0
        func map(_ p: CGPoint) -> CGPoint {
            var q = p
            if let wobble {
                q.x += wobble.offset(index, axis: 0)
                q.y += wobble.offset(index, axis: 1)
            }
            index += 1
            return CGPoint(x: origin.x + q.x * scale, y: origin.y + q.y * scale)
        }
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case let .move(p): path.move(to: map(p))
            case let .line(p): path.addLine(to: map(p))
            case let .quad(p, c):
                let cc = map(c)
                path.addQuadCurve(to: map(p), control: cc)
            case let .cubic(p, c1, c2):
                let a = map(c1), b = map(c2)
                path.addCurve(to: map(p), control1: a, control2: b)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    // MARK: - Parsing

    private static func parse(_ source: String) throws -> [Element] {
        var tokens = Tokens(source)
        var out: [Element] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character?
        while let next = tokens.peek() {
            if case let .command(c) = next {
                tokens.advance()
                command = c
                if c == "Z" || c == "z" {
                    out.append(.close)
                    current = start
                    command = nil
                }
                continue
            }
            guard let c = command else { throw ParseError.unexpected("a number before any command") }
            let relative = c.isLowercase
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch c.uppercased().first! {
            case "M":
                let p = pt(try tokens.number(c), try tokens.number(c))
                out.append(.move(p))
                current = p
                start = p
                // Further pairs after a move are lines, as in SVG.
                command = relative ? "l" : "L"
            case "L":
                let p = pt(try tokens.number(c), try tokens.number(c))
                out.append(.line(p))
                current = p
            case "H":
                let x = try tokens.number(c)
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                out.append(.line(p))
                current = p
            case "V":
                let y = try tokens.number(c)
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                out.append(.line(p))
                current = p
            case "Q":
                let control = pt(try tokens.number(c), try tokens.number(c))
                let p = pt(try tokens.number(c), try tokens.number(c))
                out.append(.quad(p, control: control))
                current = p
            case "C":
                let c1 = pt(try tokens.number(c), try tokens.number(c))
                let c2 = pt(try tokens.number(c), try tokens.number(c))
                let p = pt(try tokens.number(c), try tokens.number(c))
                out.append(.cubic(p, control1: c1, control2: c2))
                current = p
            default:
                throw ParseError.unexpected(String(c))
            }
        }
        return out
    }

    private struct Tokens {
        enum Token { case command(Character), number(CGFloat) }
        private var items: [Token] = []
        private var position = 0

        init(_ source: String) {
            var buffer = ""
            func flush() {
                if !buffer.isEmpty, let value = Double(buffer) { items.append(.number(CGFloat(value))) }
                buffer = ""
            }
            for ch in source {
                if "MmLlHhVvQqCcZz".contains(ch) {
                    flush()
                    items.append(.command(ch))
                } else if ch == "-" {
                    // A minus starts a new number unless it follows an exponent.
                    if buffer.last == "e" || buffer.last == "E" { buffer.append(ch) } else { flush(); buffer.append(ch) }
                } else if ch == "." {
                    // ".5.5" is two numbers.
                    if buffer.contains(".") { flush() }
                    buffer.append(ch)
                } else if ch.isNumber || ch == "e" || ch == "E" {
                    buffer.append(ch)
                } else {
                    flush()
                }
            }
            flush()
        }

        func peek() -> Token? { position < items.count ? items[position] : nil }
        mutating func advance() { position += 1 }
        mutating func number(_ command: Character) throws -> CGFloat {
            guard position < items.count, case let .number(value) = items[position] else {
                throw ParseError.missingNumbers(command)
            }
            position += 1
            return value
        }
    }
}

/// A small, repeatable shake for the points of a path: the same seed always
/// moves the same point the same way.
public struct Wobble: Hashable, Sendable {
    public let seed: UInt64
    public let amount: CGFloat

    public init(id: String, amount: CGFloat) {
        // FNV-1a: stable across launches, unlike `hashValue`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        seed = hash
        self.amount = amount
    }

    func offset(_ index: Int, axis: Int) -> CGFloat {
        var x = seed ^ (UInt64(index * 2 + axis) &* 0x9E37_79B9_7F4A_7C15)
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        let unit = CGFloat(x % 10_000) / 10_000 // 0..<1
        return (unit * 2 - 1) * amount
    }
}
