import Foundation

/// A WGS84 coordinate. Deliberately a plain value type so the package never
/// depends on CoreLocation or a map SDK.
public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Builds a coordinate from a GeoJSON-ordered `[lon, lat(, ele)]` array.
    /// Returns `nil` when the array has fewer than two elements.
    public init?(geoJSON: [Double]) {
        guard geoJSON.count >= 2 else { return nil }
        self.init(latitude: geoJSON[1], longitude: geoJSON[0])
    }

    /// GeoJSON ordering: `[longitude, latitude]`.
    public var geoJSON: [Double] { [longitude, latitude] }

    public var isValid: Bool {
        latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180
    }
}

/// A bounding box in degrees, matching the API's `mapRegion` / `boundingBox`.
public struct BoundingBox: Codable, Hashable, Sendable {
    public var minLat: Double
    public var minLon: Double
    public var maxLat: Double
    public var maxLon: Double

    public init(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        self.minLat = minLat
        self.minLon = minLon
        self.maxLat = maxLat
        self.maxLon = maxLon
    }

    public func contains(_ coordinate: Coordinate) -> Bool {
        coordinate.latitude >= minLat && coordinate.latitude <= maxLat
            && coordinate.longitude >= minLon && coordinate.longitude <= maxLon
    }

    public var center: Coordinate {
        Coordinate(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    }

    public static func enclosing(_ coordinates: [Coordinate]) -> BoundingBox? {
        guard let first = coordinates.first else { return nil }
        var box = BoundingBox(minLat: first.latitude, minLon: first.longitude, maxLat: first.latitude, maxLon: first.longitude)
        for c in coordinates.dropFirst() {
            box.minLat = min(box.minLat, c.latitude)
            box.maxLat = max(box.maxLat, c.latitude)
            box.minLon = min(box.minLon, c.longitude)
            box.maxLon = max(box.maxLon, c.longitude)
        }
        return box
    }
}
