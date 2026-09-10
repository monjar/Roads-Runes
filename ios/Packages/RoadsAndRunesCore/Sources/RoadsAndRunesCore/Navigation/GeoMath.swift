import Foundation

/// Geodesic helpers. Distances in metres, bearings in degrees clockwise from north.
public enum GeoMath {
    public static let earthRadiusMeters = 6_371_008.8

    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inlinable public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Great-circle distance (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLat = lat2 - lat1
        let dLon = radians(b.longitude - a.longitude)
        let sinLat = sin(dLat / 2), sinLon = sin(dLon / 2)
        let h = sinLat * sinLat + cos(lat1) * cos(lat2) * sinLon * sinLon
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, normalised to 0..<360.
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = radians(a.latitude), lat2 = radians(b.latitude)
        let dLon = radians(b.longitude - a.longitude)
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalizeBearing(degrees(atan2(y, x)))
    }

    public static func normalizeBearing(_ bearing: Double) -> Double {
        var value = bearing.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    /// Signed smallest difference `to - from` in (-180, 180].
    public static func bearingDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }

    /// Point reached after travelling `distanceMeters` along `bearingDegrees`.
    public static func destination(from origin: Coordinate, bearingDegrees: Double, distanceMeters: Double) -> Coordinate {
        let angular = distanceMeters / earthRadiusMeters
        let theta = radians(bearingDegrees)
        let lat1 = radians(origin.latitude), lon1 = radians(origin.longitude)
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        var lonDeg = degrees(lon2)
        if lonDeg > 180 { lonDeg -= 360 }
        if lonDeg < -180 { lonDeg += 360 }
        return Coordinate(latitude: degrees(lat2), longitude: lonDeg)
    }

    /// Result of projecting a point onto a segment.
    public struct SegmentProjection: Hashable, Sendable {
        /// Perpendicular distance from the point to the segment (metres).
        public var distanceMeters: Double
        /// Position along the segment, 0 at `a`, 1 at `b` (clamped).
        public var fraction: Double
        /// The closest point on the segment.
        public var point: Coordinate

        public init(distanceMeters: Double, fraction: Double, point: Coordinate) {
            self.distanceMeters = distanceMeters
            self.fraction = fraction
            self.point = point
        }
    }

    /// Projects `p` onto segment `a`–`b` using a local equirectangular
    /// approximation; accurate to well under 1 % for segments shorter than ~1 km.
    public static func project(_ p: Coordinate, ontoSegment a: Coordinate, _ b: Coordinate) -> SegmentProjection {
        let refLat = radians((a.latitude + b.latitude + p.latitude) / 3)
        let scaleX = earthRadiusMeters * cos(refLat)
        let scaleY = earthRadiusMeters
        let ax = radians(a.longitude) * scaleX, ay = radians(a.latitude) * scaleY
        let bx = radians(b.longitude) * scaleX, by = radians(b.latitude) * scaleY
        let px = radians(p.longitude) * scaleX, py = radians(p.latitude) * scaleY
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        var t = 0.0
        if lengthSquared > 0 {
            t = ((px - ax) * dx + (py - ay) * dy) / lengthSquared
            t = min(1, max(0, t))
        }
        let cx = ax + t * dx, cy = ay + t * dy
        let distance = sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
        let point = Coordinate(latitude: degrees(cy / scaleY), longitude: degrees(cx / scaleX))
        return SegmentProjection(distanceMeters: distance, fraction: t, point: point)
    }

    /// Shortest distance from `p` to the segment `a`–`b`.
    public static func distance(from p: Coordinate, toSegment a: Coordinate, _ b: Coordinate) -> Double {
        project(p, ontoSegment: a, b).distanceMeters
    }

    /// Total length of a path in metres.
    public static func pathLength(_ path: [Coordinate]) -> Double {
        guard path.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<path.count {
            total += distance(path[i - 1], path[i])
        }
        return total
    }

    /// Cumulative distance at each vertex (first element is 0).
    public static func cumulativeDistances(_ path: [Coordinate]) -> [Double] {
        guard !path.isEmpty else { return [] }
        var result = [0.0]
        result.reserveCapacity(path.count)
        for i in 1..<path.count {
            result.append(result[i - 1] + distance(path[i - 1], path[i]))
        }
        return result
    }
}
