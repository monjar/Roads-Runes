import Foundation

public struct TimedPoint: Equatable, Sendable {
    public var t: Double
    public var coordinate: Coordinate

    public init(t: Double, coordinate: Coordinate) {
        self.t = t
        self.coordinate = coordinate
    }
}

public struct PaceWindow: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var seconds: Double
    public var meters: Double

    public var paceSecondsPerKm: Double { seconds / (meters / 1000) }
}

/// The fastest stretch of a given length: a port of the server's `best_pace_window`
/// (world_objects/claims.py), same rules, so the phone's live progress is what pays.
public enum PaceFinder {
    public static func bestWindow(
        _ points: [TimedPoint], windowMeters: Double, speedCap: Double, near: [Bool]? = nil, maxGap: Double = 60
    ) -> PaceWindow? {
        let n = points.count
        guard n >= 3, windowMeters > 0 else { return nil }
        var cum = [Double](repeating: 0, count: n)
        var bad = [Int](repeating: 0, count: n)
        var nearPrefix = [Int](repeating: 0, count: n)
        for i in 1..<n {
            let d = GeoMath.distance(points[i - 1].coordinate, points[i].coordinate)
            let dt = points[i].t - points[i - 1].t
            cum[i] = cum[i - 1] + d
            bad[i] = bad[i - 1] + ((dt <= 0 || dt > maxGap || d / dt > speedCap) ? 1 : 0)
        }
        for i in 0..<n {
            nearPrefix[i] = (i > 0 ? nearPrefix[i - 1] : 0) + ((near?[i] ?? true) ? 1 : 0)
        }
        var best: PaceWindow?
        var j = 0
        for i in 0..<n {
            while j < n, cum[j] - cum[i] < windowMeters { j += 1 }
            if j >= n { break }
            if bad[j] - bad[i] > 0 || j - i < 2 { continue }
            if nearPrefix[j] - (i > 0 ? nearPrefix[i - 1] : 0) == 0 { continue }
            let over = cum[j] - cum[i] - windowMeters
            let segment = cum[j] - cum[j - 1]
            let tEnd = points[j].t - (points[j].t - points[j - 1].t) * (segment > 0 ? over / segment : 0)
            let seconds = tEnd - points[i].t
            if seconds <= 0 { continue }
            if best == nil || seconds < best!.seconds {
                best = PaceWindow(start: i, end: j, seconds: seconds, meters: windowMeters)
            }
        }
        return best
    }
}
