import Foundation

/// Locale-independent formatting of metres / seconds / m/s for the UI.
/// All API values are metric; this is the only place units are converted.
public struct UnitFormatter: Hashable, Sendable {
    public static let metersPerMile = 1609.344
    public static let feetPerMeter = 3.280_839_895

    public var units: Units

    public init(units: Units) {
        self.units = units
    }

    public var isImperial: Bool { units == .imperial }

    public var distanceUnitLabel: String { isImperial ? "mi" : "km" }
    public var shortDistanceUnitLabel: String { isImperial ? "ft" : "m" }
    public var speedUnitLabel: String { isImperial ? "mph" : "km/h" }

    /// "180 m", "12.6 km" / "590 ft", "7.8 mi".
    public func distance(meters: Double) -> String {
        let value = max(0, meters)
        if isImperial {
            let miles = value / Self.metersPerMile
            if miles < 0.1 {
                return "\(Int((value * Self.feetPerMeter).rounded())) ft"
            }
            return miles < 100 ? String(format: "%.1f mi", miles) : String(format: "%.0f mi", miles)
        }
        if value < 1000 {
            return "\(Int(value.rounded())) m"
        }
        let km = value / 1000
        return km < 100 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }

    /// Elevation: "340 m" / "1115 ft".
    public func elevation(meters: Double) -> String {
        if isImperial {
            return "\(Int((meters * Self.feetPerMeter).rounded())) ft"
        }
        return "\(Int(meters.rounded())) m"
    }

    /// "2h 04m", "34 min", "45 s".
    public func duration(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h " + String(format: "%02d", minutes) + "m"
        }
        if minutes > 0 {
            return "\(minutes) min"
        }
        return "\(total) s"
    }

    /// "15.5 km/h" / "9.6 mph".
    public func speed(metersPerSecond: Double) -> String {
        let value = max(0, metersPerSecond)
        if isImperial {
            return String(format: "%.1f mph", value * 3600 / Self.metersPerMile)
        }
        return String(format: "%.1f km/h", value * 3.6)
    }

    /// Numeric value only, for large ride metrics with a separate unit label.
    public func distanceValue(meters: Double) -> Double {
        isImperial ? meters / Self.metersPerMile : meters / 1000
    }

    public func speedValue(metersPerSecond: Double) -> Double {
        isImperial ? metersPerSecond * 3600 / Self.metersPerMile : metersPerSecond * 3.6
    }
}
