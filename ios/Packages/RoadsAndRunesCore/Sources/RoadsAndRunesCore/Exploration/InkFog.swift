import Foundation

/// The fog as ink (docs/ROADMAP.md, 0.7.0): ground not yet read is a paper-coloured
/// wash over the map, with the read ground cut out of it. The read cells are joined
/// into outlines (H3 does that, in the app), their corners softened so they stop
/// reading as hexagons, and the wash is one polygon: the view's bounds with the
/// outlines as holes. Pure; drawn by the map.
public enum InkFog {
    /// Chaikin's corner cutting, `passes` times, on a closed ring: each corner is
    /// replaced by two points a quarter of the way along its edges.
    public static func soften(_ ring: [Coordinate], passes: Int = 2) -> [Coordinate] {
        var points = ring
        if let first = points.first, let last = points.last, first == last { points.removeLast() }
        guard points.count >= 3 else { return ring }
        for _ in 0..<max(0, passes) {
            var next: [Coordinate] = []
            next.reserveCapacity(points.count * 2)
            for (i, a) in points.enumerated() {
                let b = points[(i + 1) % points.count]
                next.append(Coordinate(latitude: a.latitude * 0.75 + b.latitude * 0.25, longitude: a.longitude * 0.75 + b.longitude * 0.25))
                next.append(Coordinate(latitude: a.latitude * 0.25 + b.latitude * 0.75, longitude: a.longitude * 0.25 + b.longitude * 0.75))
            }
            points = next
        }
        return points + [points[0]]
    }

    /// The wash: the bounds as the outer ring and each read outline as a hole.
    /// `outlines` are the outer rings of the joined read cells.
    public static func wash(bounds: BoundingBox, outlines: [[Coordinate]], passes: Int = 2) -> [[Coordinate]] {
        let outer = [
            Coordinate(latitude: bounds.minLat, longitude: bounds.minLon),
            Coordinate(latitude: bounds.minLat, longitude: bounds.maxLon),
            Coordinate(latitude: bounds.maxLat, longitude: bounds.maxLon),
            Coordinate(latitude: bounds.maxLat, longitude: bounds.minLon),
            Coordinate(latitude: bounds.minLat, longitude: bounds.minLon),
        ]
        let holes = outlines
            .filter { $0.count >= 3 }
            .map { soften($0, passes: passes) }
            .filter { ring in ring.contains { bounds.contains($0) } }
        return [outer] + holes
    }

    /// A bounds a little larger than the map shows, so the wash's edge is never seen.
    public static func padded(_ box: BoundingBox, by fraction: Double = 0.5) -> BoundingBox {
        let dLat = (box.maxLat - box.minLat) * fraction
        let dLon = (box.maxLon - box.minLon) * fraction
        return BoundingBox(minLat: box.minLat - dLat, minLon: box.minLon - dLon, maxLat: box.maxLat + dLat, maxLon: box.maxLon + dLon)
    }

    /// The nearest unread ground from here, for the World tab's frontier chevron:
    /// the nearest cell centre that is not read, among the cells round the read ones.
    public static func nearestUnread(from position: Coordinate, read: Set<String>, indexing: any CellIndexing) -> Coordinate? {
        var best: (Coordinate, Double)?
        for cell in read {
            for neighbour in indexing.neighbours(of: cell) where !read.contains(neighbour) {
                let centre = indexing.center(of: neighbour)
                let distance = GeoMath.distance(position, centre)
                if best == nil || distance < best!.1 { best = (centre, distance) }
            }
        }
        return best?.0
    }
}
