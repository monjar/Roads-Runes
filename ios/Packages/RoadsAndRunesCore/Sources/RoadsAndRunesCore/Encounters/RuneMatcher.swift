import Foundation

/// A rune a track can trace. A port of the server's matcher (world_objects/claims.py)
/// with the same constants and vetoes, so "tracing: triangle 71%" on the phone is
/// the same triangle the server pays for.
public enum RuneShape: String, CaseIterable, Sendable {
    case triangle = "TRIANGLE"
    case square = "SQUARE"
    case star = "STAR"
    case loop = "LOOP"
    case zigzag = "ZIGZAG"

    public var closed: Bool { self != .zigzag }

    public var corners: Int {
        switch self {
        case .triangle: return 3
        case .square: return 4
        case .star: return 5
        case .loop: return 0
        case .zigzag: return 3
        }
    }
}

public struct RuneMatch: Equatable, Sendable {
    public var shape: RuneShape
    public var score: Double
    public var start: Int
    public var end: Int
    public var corners: Int
}

struct Complex: Equatable {
    var re: Double
    var im: Double

    static let zero = Complex(re: 0, im: 0)
    static func + (a: Complex, b: Complex) -> Complex { Complex(re: a.re + b.re, im: a.im + b.im) }
    static func - (a: Complex, b: Complex) -> Complex { Complex(re: a.re - b.re, im: a.im - b.im) }
    static func * (a: Complex, b: Complex) -> Complex { Complex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re) }
    static func * (a: Complex, k: Double) -> Complex { Complex(re: a.re * k, im: a.im * k) }
    static func / (a: Complex, k: Double) -> Complex { Complex(re: a.re / k, im: a.im / k) }
    static func / (a: Complex, b: Complex) -> Complex {
        let d = b.re * b.re + b.im * b.im
        return Complex(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d)
    }
    var magnitude: Double { (re * re + im * im).squareRoot() }
    var conjugate: Complex { Complex(re: re, im: -im) }
    var phaseDegrees: Double { atan2(im, re) * 180 / .pi }
    static func polar(_ r: Double, degrees: Double) -> Complex { Complex(re: r * cos(degrees * .pi / 180), im: r * sin(degrees * .pi / 180)) }
}

public enum RuneMatcher {
    public static let samples = 32
    public static let cornerTurnDegrees = 50.0
    public static let loopThreshold = 0.08
    public static let candidateLengths: [Double] = [300, 450, 675, 1000, 1500, 2250, 3000, 4000]
    public static let maxCandidates = 400

    static func localXY(_ point: Coordinate, centre: Coordinate) -> Complex {
        let x = GeoMath.radians(point.longitude - centre.longitude) * cos(GeoMath.radians(centre.latitude)) * GeoMath.earthRadiusMeters
        let y = GeoMath.radians(point.latitude - centre.latitude) * GeoMath.earthRadiusMeters
        return Complex(re: x, im: y)
    }

    static func resample(_ points: [Complex], n: Int = samples, closed: Bool) -> [Complex] {
        var pts = points
        guard pts.count >= 2 else { return Array(repeating: pts.first ?? .zero, count: n) }
        if closed { pts.append(pts[0]) }
        let lengths = zip(pts, pts.dropFirst()).map { ($1 - $0).magnitude }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return Array(repeating: pts[0], count: n) }
        let targets = (0..<n).map { closed ? total * Double($0) / Double(n) : total * Double($0) / Double(n - 1) }
        var out: [Complex] = []
        var k = 0
        var passed = 0.0
        for s in targets {
            while k < lengths.count - 1, passed + lengths[k] < s {
                passed += lengths[k]
                k += 1
            }
            let fraction = lengths[k] > 0 ? (s - passed) / lengths[k] : 0
            out.append(pts[k] + (pts[k + 1] - pts[k]) * min(1, max(0, fraction)))
        }
        return out
    }

    static func normalise(_ points: [Complex]) -> [Complex] {
        let centre = points.reduce(.zero, +) / Double(points.count)
        let shifted = points.map { $0 - centre }
        var rms = (shifted.reduce(0) { $0 + $1.magnitude * $1.magnitude } / Double(shifted.count)).squareRoot()
        if rms == 0 { rms = 1 }
        return shifted.map { $0 / rms }
    }

    static func vertices(_ shape: RuneShape) -> [Complex] {
        switch shape {
        case .triangle: return (0..<3).map { Complex.polar(1, degrees: 90 + 120 * Double($0)) }
        case .square: return (0..<4).map { Complex.polar(1, degrees: 45 + 90 * Double($0)) }
        case .star:
            let outer = (0..<5).map { Complex.polar(1, degrees: 90 + 72 * Double($0)) }
            return [0, 2, 4, 1, 3].map { outer[$0] }
        case .loop: return (0..<64).map { Complex.polar(1, degrees: 360 * Double($0) / 64) }
        case .zigzag: return (0..<5).map { Complex(re: 0.5 * Double($0), im: $0 % 2 == 1 ? 0.866 : 0) }
        }
    }

    static let templates: [RuneShape: [Complex]] = Dictionary(uniqueKeysWithValues: RuneShape.allCases.map {
        ($0, normalise(resample(vertices($0), closed: $0.closed)))
    })

    static func procrustesScore(_ a: [Complex], _ b: [Complex]) -> Double {
        var s = Complex.zero
        for (ak, bk) in zip(a, b) { s = s + ak.conjugate * bk }
        let magnitude = s.magnitude
        if magnitude == 0 { return 2 }
        let rotation = s / magnitude
        var total = 0.0
        for (ak, bk) in zip(a, b) { total += (ak * rotation - bk).magnitude }
        return total / Double(a.count)
    }

    static func scoreAgainst(_ track: [Complex], template: [Complex], closed: Bool) -> Double {
        var best = Double.infinity
        for mirrored in [track, track.map(\.conjugate)] {
            for ordered in [mirrored, Array(mirrored.reversed())] {
                let offsets = closed ? Array(0..<ordered.count) : [0]
                for offset in offsets {
                    let candidate = Array(ordered[offset...]) + Array(ordered[..<offset])
                    best = min(best, procrustesScore(candidate, template))
                }
            }
        }
        return best
    }

    /// Sharp turns measured over chords two samples wide, and the total turning.
    static func corners(_ points: [Complex], closed: Bool) -> (count: Int, total: Double) {
        let n = points.count
        guard n >= 5 else { return (0, 0) }
        func at(_ i: Int) -> Complex { closed ? points[((i % n) + n) % n] : points[max(0, min(n - 1, i))] }
        var wide = [Double](repeating: 0, count: n)
        var total = 0.0
        for k in 0..<n {
            if !closed, k < 2 || k > n - 3 { continue }
            let chordIn = at(k) - at(k - 2), chordOut = at(k + 2) - at(k)
            if chordIn.magnitude > 0, chordOut.magnitude > 0 { wide[k] = abs((chordOut / chordIn).phaseDegrees) }
        }
        for k in 0..<(closed ? n : n - 2) where closed || k > 0 {
            let stepIn = at(k) - at(k - 1), stepOut = at(k + 1) - at(k)
            if stepIn.magnitude > 0, stepOut.magnitude > 0 { total += abs((stepOut / stepIn).phaseDegrees) }
        }
        let sharp = wide.map { $0 >= cornerTurnDegrees }
        var count = 0
        for k in 0..<n {
            let before = closed ? sharp[((k - 1) % n + n) % n] : (k > 0 ? sharp[k - 1] : false)
            if sharp[k], !before { count += 1 }
        }
        if closed, count == 0, sharp.allSatisfy({ $0 }) { count = 1 }
        return (count, total)
    }

    static func classify(_ track: [Complex], threshold: Double) -> RuneMatch? {
        guard track.count >= 4 else { return nil }
        let arc = zip(track, track.dropFirst()).reduce(0) { $0 + ($1.1 - $1.0).magnitude }
        guard arc > 0 else { return nil }
        let closure = (track[0] - track[track.count - 1]).magnitude / arc
        let closedPts = normalise(resample(track, closed: true))
        let openPts = normalise(resample(track, closed: false))
        var results: [(score: Double, shape: RuneShape, count: Int)] = []
        for shape in RuneShape.allCases {
            let closed = shape.closed
            if closed, closure > (shape == .loop ? 0.12 : 0.15) { continue }
            let pts = closed ? closedPts : openPts
            let (count, total) = corners(pts, closed: closed)
            if shape == .loop {
                if count > 2 || !(300...450).contains(total) { continue }
            } else if abs(count - shape.corners) > 1 {
                continue
            }
            if shape == .star, total < 540 { continue }
            let score = scoreAgainst(pts, template: templates[shape]!, closed: closed)
            if score <= (shape == .loop ? min(threshold, loopThreshold) : threshold) {
                results.append((score, shape, count))
            }
        }
        guard !results.isEmpty else { return nil }
        results.sort { $0.score < $1.score }
        var best = results[0]
        for candidate in results.dropFirst() where candidate.score - best.score <= 0.03 && candidate.count == candidate.shape.corners && best.count != best.shape.corners {
            best = candidate
            break
        }
        return RuneMatch(shape: best.shape, score: (best.score * 10_000).rounded() / 10_000, start: 0, end: track.count - 1, corners: best.count)
    }

    /// The rune traced near `centre`, if any.
    public static func match(
        track: [Coordinate], centre: Coordinate, threshold: Double = 0.22,
        searchRadius: Double = 1000, minLength: Double = 300, maxLength: Double = 4000
    ) -> RuneMatch? {
        guard track.count >= 4 else { return nil }
        let xy = track.map { localXY($0, centre: centre) }
        let near = xy.map { $0.magnitude <= searchRadius }
        var runs: [(Int, Int)] = []
        var start: Int?
        for (i, ok) in near.enumerated() {
            if ok, start == nil { start = i } else if !ok, let s = start { runs.append((s, i - 1)); start = nil }
        }
        if let s = start { runs.append((s, near.count - 1)) }
        let lengths = candidateLengths.filter { $0 >= minLength && $0 <= maxLength }
        var candidates: [(Int, Int)] = []
        for (first, last) in runs {
            var cum = [0.0]
            if last > first { for i in (first + 1)...last { cum.append(cum[cum.count - 1] + (xy[i] - xy[i - 1]).magnitude) } }
            if cum[cum.count - 1] < minLength { continue }
            var stride = 50.0
            while true {
                var found = Set<Int>()  // encoded a * 1_000_000 + b
                var nextStartAt = 0.0
                for a in 0..<cum.count {
                    if cum[a] < nextStartAt { continue }
                    nextStartAt = cum[a] + stride
                    let remaining = cum[cum.count - 1] - cum[a]
                    if remaining < minLength { break }
                    for length in lengths {
                        guard let b = ((a + 1)..<cum.count).first(where: { cum[$0] - cum[a] >= length }) else { break }
                        found.insert(a * 1_000_000 + b)
                    }
                    if remaining <= maxLength { found.insert(a * 1_000_000 + cum.count - 1) }
                    var skipUntil = 0.0
                    if a + 1 < cum.count {
                        for b in (a + 1)..<cum.count {
                            let arc = cum[b] - cum[a]
                            if arc < minLength || cum[b] < skipUntil { continue }
                            if arc > maxLength { break }
                            if (xy[first + b] - xy[first + a]).magnitude <= max(30, 0.08 * arc) {
                                found.insert(a * 1_000_000 + b)
                                skipUntil = cum[b] + 100
                            }
                        }
                    }
                }
                if found.count <= maxCandidates || stride >= 1600 {
                    candidates += found.sorted().map { (first + $0 / 1_000_000, first + $0 % 1_000_000) }
                    break
                }
                stride *= 2
            }
        }
        var best: RuneMatch?
        for (a, b) in candidates.prefix(maxCandidates) {
            guard var match = classify(Array(xy[a...b]), threshold: threshold) else { continue }
            match.start = a
            match.end = b
            if best == nil || match.score < best!.score { best = match }
        }
        return best
    }
}
