import Foundation

/// Google Encoded Polyline Algorithm Format (precision 1e5).
public enum Polyline {
    public static let defaultPrecision = 1e5

    public static func encode(_ coordinates: [Coordinate], precision: Double = defaultPrecision) -> String {
        var output = ""
        var previousLat = 0
        var previousLon = 0
        for coordinate in coordinates {
            let lat = Int((coordinate.latitude * precision).rounded())
            let lon = Int((coordinate.longitude * precision).rounded())
            encodeValue(lat - previousLat, into: &output)
            encodeValue(lon - previousLon, into: &output)
            previousLat = lat
            previousLon = lon
        }
        return output
    }

    public static func decode(_ encoded: String, precision: Double = defaultPrecision) -> [Coordinate] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var lat = 0
        var lon = 0
        var coordinates: [Coordinate] = []

        func nextValue() -> Int? {
            var result = 0
            var shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard byte >= 0 else { return nil }
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 {
                    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
                }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            coordinates.append(Coordinate(latitude: Double(lat) / precision, longitude: Double(lon) / precision))
        }
        return coordinates
    }

    private static func encodeValue(_ value: Int, into output: inout String) {
        var v = value < 0 ? ~(value << 1) : (value << 1)
        while v >= 0x20 {
            let chunk = (0x20 | (v & 0x1F)) + 63
            output.unicodeScalars.append(UnicodeScalar(UInt8(chunk)))
            v >>= 5
        }
        output.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
    }
}
