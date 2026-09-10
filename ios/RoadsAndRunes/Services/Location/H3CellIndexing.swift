import Foundation
import H3
import RoadsAndRunesCore

/// `CellIndexing` implementation backed by the uber/h3 C library.
/// Isolated here so the rest of the app depends only on the protocol.
struct H3CellIndexing: CellIndexing {
    func cell(latitude: Double, longitude: Double, resolution: Int) -> String {
        var coord = LatLng(lat: degsToRads(latitude), lng: degsToRads(longitude))
        var index: H3Index = 0
        let error = latLngToCell(&coord, Int32(resolution), &index)
        guard error == 0 else { return "" }
        return Self.string(from: index)
    }

    func neighbours(of cell: String) -> [String] {
        let index = Self.index(from: cell)
        guard index != 0 else { return [] }
        var maxSize: Int64 = 0
        guard maxGridDiskSize(1, &maxSize) == 0 else { return [] }
        var out = [H3Index](repeating: 0, count: Int(maxSize))
        guard gridDisk(index, 1, &out) == 0 else { return [] }
        return out.filter { $0 != 0 && $0 != index }.map(Self.string(from:))
    }

    func boundary(of cell: String) -> [Coordinate] {
        let index = Self.index(from: cell)
        guard index != 0 else { return [] }
        var cellBoundary = CellBoundary()
        guard cellToBoundary(index, &cellBoundary) == 0 else { return [] }
        let count = Int(cellBoundary.numVerts)
        return withUnsafeBytes(of: &cellBoundary.verts) { raw -> [Coordinate] in
            let verts = raw.bindMemory(to: LatLng.self)
            return (0..<count).map { i in
                Coordinate(latitude: radsToDegs(verts[i].lat), longitude: radsToDegs(verts[i].lng))
            }
        }
    }

    func center(of cell: String) -> Coordinate {
        let index = Self.index(from: cell)
        var latLng = LatLng(lat: 0, lng: 0)
        guard index != 0, cellToLatLng(index, &latLng) == 0 else { return Coordinate(latitude: 0, longitude: 0) }
        return Coordinate(latitude: radsToDegs(latLng.lat), longitude: radsToDegs(latLng.lng))
    }

    private static func string(from index: H3Index) -> String {
        String(index, radix: 16)
    }

    private static func index(from string: String) -> H3Index {
        H3Index(string, radix: 16) ?? 0
    }
}
