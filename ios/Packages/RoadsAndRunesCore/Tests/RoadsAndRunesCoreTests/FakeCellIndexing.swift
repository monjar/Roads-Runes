import Foundation
@testable import RoadsAndRunesCore

/// Buckets coordinates into a 0.002° grid so exploration logic can be tested
/// without H3. Cell ids look like `"25745_-20"`.
struct FakeCellIndexing: CellIndexing {
    static let step = 0.002

    func cell(latitude: Double, longitude: Double, resolution: Int) -> String {
        let row = Int((latitude / Self.step).rounded())
        let column = Int((longitude / Self.step).rounded())
        return "\(row)_\(column)"
    }

    func neighbours(of cell: String) -> [String] {
        guard let parsed = parse(cell) else { return [] }
        let (row, column) = parsed
        var result: [String] = []
        for dr in -1...1 {
            for dc in -1...1 where dr != 0 || dc != 0 {
                result.append("\(row + dr)_\(column + dc)")
            }
        }
        return result
    }

    func boundary(of cell: String) -> [Coordinate] {
        let c = center(of: cell)
        let half = Self.step / 2
        return [
            Coordinate(latitude: c.latitude - half, longitude: c.longitude - half),
            Coordinate(latitude: c.latitude - half, longitude: c.longitude + half),
            Coordinate(latitude: c.latitude + half, longitude: c.longitude + half),
            Coordinate(latitude: c.latitude + half, longitude: c.longitude - half),
        ]
    }

    func center(of cell: String) -> Coordinate {
        guard let parsed = parse(cell) else { return Coordinate(latitude: 0, longitude: 0) }
        let (row, column) = parsed
        return Coordinate(latitude: Double(row) * Self.step, longitude: Double(column) * Self.step)
    }

    private func parse(_ cell: String) -> (Int, Int)? {
        let parts = cell.split(separator: "_")
        guard parts.count == 2, let row = Int(parts[0]), let column = Int(parts[1]) else { return nil }
        return (row, column)
    }
}
