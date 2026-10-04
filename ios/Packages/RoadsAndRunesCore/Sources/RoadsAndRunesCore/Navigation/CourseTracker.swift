import Foundation

/// Which way the rider is heading, from where they have been: the bearing from
/// the last place they were to where they are now, once they have moved far
/// enough for it to mean something. Standing still keeps the last heading, so
/// a pause at a junction does not spin the arrow; before any movement there is
/// none. Fed fix by fix on the phone, and by the positions the phone sends on
/// the Watch, whose map dot had no direction at all.
public struct CourseTracker: Sendable {
    /// Less than this between two places and GPS noise could point anywhere.
    public static let minimumStepMeters: Double = 4

    public private(set) var course: Double?
    private var anchor: Coordinate?

    public init() {}

    /// The course after this position, in degrees from north (0..<360).
    @discardableResult
    public mutating func update(_ position: Coordinate) -> Double? {
        guard let from = anchor else {
            anchor = position
            return course
        }
        if GeoMath.distance(from, position) >= Self.minimumStepMeters {
            course = GeoMath.bearing(from: from, to: position)
            anchor = position
        }
        return course
    }

    public mutating func reset() {
        course = nil
        anchor = nil
    }
}
