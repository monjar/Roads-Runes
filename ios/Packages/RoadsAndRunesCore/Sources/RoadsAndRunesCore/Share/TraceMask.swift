import Foundation

/// The home masking promised in docs/PRIVACY.md, for the share card (0.7.3): a
/// trace drawn on a card loses its first and last kilometre, so where a journey
/// starts and ends (usually a door) is never on it. A trace too short to keep
/// anything worth drawing once masked is not offered at all.
public enum TraceMask {
    /// How much is cut from each end.
    public static let trimMeters: Double = 1000
    /// The shortest trace that may be added to a card.
    public static let minimumMeters: Double = 2500
    /// What the card says when the trace is shorter than that.
    public static let tooShortLine = "Too short to share safely."

    /// Whether `coords` is long enough to add to a card at all.
    public static func canShare(_ coords: [Coordinate], minimumMeters: Double = minimumMeters) -> Bool {
        coords.count >= 2 && GeoMath.pathLength(coords) >= minimumMeters
    }

    /// The trace with `trimMeters` cut from each end, measured along it, the cuts
    /// placed exactly (between two fixes where they fall). Empty when nothing is
    /// left: a trace no longer than both cuts together is all home.
    public static func masked(_ coords: [Coordinate], trimMeters: Double = trimMeters) -> [Coordinate] {
        guard coords.count >= 2 else { return [] }
        let trim = max(0, trimMeters)
        let distances = GeoMath.cumulativeDistances(coords)
        // A metre's grace, so a trace exactly as long as both cuts is not left a sliver.
        guard let total = distances.last, total > 2 * trim + 1 else { return [] }
        if trim == 0 { return coords }
        let start = trim
        let end = total - trim
        var out: [Coordinate] = [point(at: start, in: coords, distances: distances)]
        for (index, coordinate) in coords.enumerated() where distances[index] > start && distances[index] < end {
            out.append(coordinate)
        }
        out.append(point(at: end, in: coords, distances: distances))
        return out
    }

    /// The masked trace, or nil when the trace may not be shared.
    public static func shareable(_ coords: [Coordinate], trimMeters: Double = trimMeters, minimumMeters: Double = minimumMeters) -> [Coordinate]? {
        guard canShare(coords, minimumMeters: minimumMeters) else { return nil }
        let masked = masked(coords, trimMeters: trimMeters)
        return masked.count >= 2 ? masked : nil
    }

    /// The point `distance` metres along the path, between the two fixes it falls between.
    static func point(at distance: Double, in coords: [Coordinate], distances: [Double]) -> Coordinate {
        guard let after = distances.firstIndex(where: { $0 >= distance }) else { return coords[coords.count - 1] }
        guard after > 0 else { return coords[0] }
        let before = after - 1
        let span = distances[after] - distances[before]
        let t = span > 0 ? (distance - distances[before]) / span : 0
        let a = coords[before]
        let b = coords[after]
        return Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}
