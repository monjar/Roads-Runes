import Foundation

/// The way back to a route for a rider who has left it: the nearest point of what
/// was still to ride, how far it is, and which way. Worked out on the phone from
/// the route it already has, so it is there with no signal at all.
public struct RejoinGuide: Hashable, Sendable {
    public var point: Coordinate
    public var distanceMeters: Double
    public var bearingDegrees: Double

    public init(point: Coordinate, distanceMeters: Double, bearingDegrees: Double) {
        self.point = point
        self.distanceMeters = distanceMeters
        self.bearingDegrees = bearingDegrees
    }

    public init(from position: Coordinate, to point: Coordinate) {
        self.init(point: point, distanceMeters: GeoMath.distance(position, point), bearingDegrees: GeoMath.bearing(from: position, to: point))
    }

    /// "north-east": one of eight, which is as fine as a glance at a handlebar can use.
    public var compass: String { Self.compassPoint(for: bearingDegrees) }

    public static func compassPoint(for bearing: Double) -> String {
        let points = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        let index = Int((GeoMath.normalizeBearing(bearing) + 22.5) / 45) % points.count
        return points[index]
    }
}
