import Foundation

/// Abstraction over the H3 library (injected by the app; this package has no
/// H3 dependency so it builds anywhere, including CI on Linux).
public protocol CellIndexing: Sendable {
    /// H3 index (hex string) containing the point at the given resolution.
    func cell(latitude: Double, longitude: Double, resolution: Int) -> String
    /// The ring of adjacent cells.
    func neighbours(of cell: String) -> [String]
    /// Polygon boundary of the cell (closed or open; renderers close it).
    func boundary(of cell: String) -> [Coordinate]
    /// Centroid of the cell.
    func center(of cell: String) -> Coordinate
}

extension CellIndexing {
    public func cell(at coordinate: Coordinate, resolution: Int) -> String {
        cell(latitude: coordinate.latitude, longitude: coordinate.longitude, resolution: resolution)
    }
}

/// Default H3 resolution used by the world map (`/config` may override).
public enum ExplorationDefaults {
    public static let h3Resolution = 9
    /// Distance ridden inside a cell before it counts as EXPLORED.
    public static let exploredThresholdMeters = 400.0
}
