import Foundation

public enum MapDetail: String, Codable, Hashable, Sendable {
    case full
    case balanced
    case minimal
}

/// Location / UI cadence for each `BatteryMode` (PRODUCT_SPEC §49).
///
/// Navigation accuracy never drops below `minimumNavigationAccuracyMeters`
/// (i.e. the requested accuracy is never coarser than 30 m) even in ENDURANCE,
/// because turn prompts depend on it.
public struct BatteryPolicy: Hashable, Sendable {
    public static let minimumNavigationAccuracyMeters = 30.0

    public var mode: BatteryMode
    public var desiredAccuracyMeters: Double
    public var distanceFilterMeters: Double
    public var uiUpdateInterval: TimeInterval
    public var mapDetail: MapDetail
    public var watchUpdateInterval: TimeInterval

    public init(mode: BatteryMode, desiredAccuracyMeters: Double, distanceFilterMeters: Double, uiUpdateInterval: TimeInterval, mapDetail: MapDetail, watchUpdateInterval: TimeInterval) {
        self.mode = mode
        self.desiredAccuracyMeters = min(desiredAccuracyMeters, Self.minimumNavigationAccuracyMeters)
        self.distanceFilterMeters = distanceFilterMeters
        self.uiUpdateInterval = uiUpdateInterval
        self.mapDetail = mapDetail
        self.watchUpdateInterval = watchUpdateInterval
    }

    public static let full = BatteryPolicy(mode: .full, desiredAccuracyMeters: 5, distanceFilterMeters: 3, uiUpdateInterval: 1, mapDetail: .full, watchUpdateInterval: 1)
    public static let balanced = BatteryPolicy(mode: .balanced, desiredAccuracyMeters: 10, distanceFilterMeters: 8, uiUpdateInterval: 2, mapDetail: .balanced, watchUpdateInterval: 3)
    public static let endurance = BatteryPolicy(mode: .endurance, desiredAccuracyMeters: 30, distanceFilterMeters: 20, uiUpdateInterval: 5, mapDetail: .minimal, watchUpdateInterval: 10)

    /// Unknown modes fall back to BALANCED.
    public static func policy(for mode: BatteryMode) -> BatteryPolicy {
        switch mode {
        case .full: return .full
        case .balanced: return .balanced
        case .endurance: return .endurance
        case .unknown: return .balanced
        }
    }
}
