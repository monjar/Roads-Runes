import Foundation

/// A location sample from CoreLocation / the Watch, in plain types.
public struct LocationFix: Codable, Hashable, Sendable {
    public var coordinate: Coordinate
    public var timestamp: Date
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    /// Speed reported by the device (m/s), if any. Negative values mean unknown.
    public var speed: Double?
    public var heartRate: Int?

    public init(coordinate: Coordinate, timestamp: Date, altitude: Double? = nil, horizontalAccuracy: Double? = nil, speed: Double? = nil, heartRate: Int? = nil) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.heartRate = heartRate
    }

    /// Upload representation.
    public var ridePoint: RidePoint {
        RidePoint(
            latitude: coordinate.latitude, longitude: coordinate.longitude, timestamp: timestamp,
            altitudeMeters: altitude, horizontalAccuracyMeters: horizontalAccuracy,
            speedMps: speed.flatMap { $0 >= 0 ? $0 : nil }, heartRateBpm: heartRate
        )
    }
}

/// Persistable summary of `RideStatistics`.
public struct RideSnapshot: Codable, Hashable, Sendable {
    public var distanceMeters: Double
    public var elapsedSeconds: Double
    public var movingSeconds: Double
    public var elevationGainMeters: Double
    public var currentSpeedMps: Double
    public var averageSpeedMps: Double
    public var maxSpeedMps: Double
    public var lastHeartRateBpm: Int?
    public var averageHeartRateBpm: Double?
    public var fixCount: Int
    public var acceptedFixCount: Int
    public var startedAt: Date?
    public var lastFixAt: Date?

    public init(distanceMeters: Double = 0, elapsedSeconds: Double = 0, movingSeconds: Double = 0, elevationGainMeters: Double = 0, currentSpeedMps: Double = 0, averageSpeedMps: Double = 0, maxSpeedMps: Double = 0, lastHeartRateBpm: Int? = nil, averageHeartRateBpm: Double? = nil, fixCount: Int = 0, acceptedFixCount: Int = 0, startedAt: Date? = nil, lastFixAt: Date? = nil) {
        self.distanceMeters = distanceMeters
        self.elapsedSeconds = elapsedSeconds
        self.movingSeconds = movingSeconds
        self.elevationGainMeters = elevationGainMeters
        self.currentSpeedMps = currentSpeedMps
        self.averageSpeedMps = averageSpeedMps
        self.maxSpeedMps = maxSpeedMps
        self.lastHeartRateBpm = lastHeartRateBpm
        self.averageHeartRateBpm = averageHeartRateBpm
        self.fixCount = fixCount
        self.acceptedFixCount = acceptedFixCount
        self.startedAt = startedAt
        self.lastFixAt = lastFixAt
    }
}

/// Accumulates ride metrics from location fixes.
///
/// - Fixes with horizontal accuracy worse than `maxAccuracyMeters` are ignored.
/// - Fixes implying a speed above `maxPlausibleSpeedMps` are ignored (GPS jumps).
/// - Moving time counts intervals at or above `movingSpeedThresholdMps`.
/// - Elevation gain uses `elevationHysteresisMeters` to filter altimeter noise.
public struct RideStatistics: Hashable, Sendable {
    public static let maxAccuracyMeters = 50.0
    public static let maxPlausibleSpeedMps = 25.0
    public static let movingSpeedThresholdMps = 0.5
    public static let elevationHysteresisMeters = 3.0

    public private(set) var distanceMeters: Double = 0
    public private(set) var movingSeconds: Double = 0
    public private(set) var elevationGainMeters: Double = 0
    public private(set) var currentSpeedMps: Double = 0
    public private(set) var maxSpeedMps: Double = 0
    public private(set) var lastHeartRateBpm: Int?
    public private(set) var fixCount: Int = 0
    public private(set) var acceptedFixCount: Int = 0
    public private(set) var startedAt: Date?
    public private(set) var lastFixAt: Date?
    public private(set) var lastAcceptedFix: LocationFix?

    private var elevationReference: Double?
    private var heartRateSum: Double = 0
    private var heartRateCount: Int = 0
    private var elapsedOffset: Double = 0

    public init() {}

    /// Restores totals from a persisted snapshot (crash recovery). The next
    /// accepted fix starts a fresh segment; no distance is bridged across the gap.
    public init(resuming snapshot: RideSnapshot) {
        distanceMeters = snapshot.distanceMeters
        movingSeconds = snapshot.movingSeconds
        elevationGainMeters = snapshot.elevationGainMeters
        maxSpeedMps = snapshot.maxSpeedMps
        lastHeartRateBpm = snapshot.lastHeartRateBpm
        fixCount = snapshot.fixCount
        acceptedFixCount = snapshot.acceptedFixCount
        elapsedOffset = snapshot.elapsedSeconds
        if let average = snapshot.averageHeartRateBpm, snapshot.acceptedFixCount > 0 {
            heartRateSum = average * Double(snapshot.acceptedFixCount)
            heartRateCount = snapshot.acceptedFixCount
        }
    }

    public var elapsedSeconds: Double {
        guard let start = startedAt, let last = lastFixAt else { return elapsedOffset }
        return elapsedOffset + max(0, last.timeIntervalSince(start))
    }

    public var averageSpeedMps: Double {
        guard movingSeconds > 0 else { return 0 }
        return distanceMeters / movingSeconds
    }

    public var averageHeartRateBpm: Double? {
        guard heartRateCount > 0 else { return nil }
        return heartRateSum / Double(heartRateCount)
    }

    /// Adds a fix. Returns `true` when the fix was accepted into the totals.
    @discardableResult
    public mutating func add(fix: LocationFix) -> Bool {
        fixCount += 1
        if startedAt == nil { startedAt = fix.timestamp }
        lastFixAt = max(lastFixAt ?? fix.timestamp, fix.timestamp)

        if let accuracy = fix.horizontalAccuracy, accuracy > Self.maxAccuracyMeters {
            return false
        }
        if let reported = fix.speed, reported > Self.maxPlausibleSpeedMps {
            return false
        }

        var speed = fix.speed.flatMap { $0 >= 0 ? $0 : nil }
        if let previous = lastAcceptedFix {
            let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
            guard dt > 0 else { return false }
            let step = GeoMath.distance(previous.coordinate, fix.coordinate)
            let computedSpeed = step / dt
            if computedSpeed > Self.maxPlausibleSpeedMps {
                return false
            }
            if speed == nil { speed = computedSpeed }
            distanceMeters += step
            if (speed ?? computedSpeed) >= Self.movingSpeedThresholdMps {
                movingSeconds += dt
            }
        }

        acceptedFixCount += 1
        lastAcceptedFix = fix
        currentSpeedMps = speed ?? 0
        maxSpeedMps = max(maxSpeedMps, currentSpeedMps)

        if let altitude = fix.altitude {
            if let reference = elevationReference {
                if altitude - reference >= Self.elevationHysteresisMeters {
                    elevationGainMeters += altitude - reference
                    elevationReference = altitude
                } else if reference - altitude >= Self.elevationHysteresisMeters {
                    elevationReference = altitude
                }
            } else {
                elevationReference = altitude
            }
        }

        if let heartRate = fix.heartRate, heartRate > 0 {
            lastHeartRateBpm = heartRate
            heartRateSum += Double(heartRate)
            heartRateCount += 1
        }
        return true
    }

    public var snapshot: RideSnapshot {
        RideSnapshot(
            distanceMeters: distanceMeters,
            elapsedSeconds: elapsedSeconds,
            movingSeconds: movingSeconds,
            elevationGainMeters: elevationGainMeters,
            currentSpeedMps: currentSpeedMps,
            averageSpeedMps: averageSpeedMps,
            maxSpeedMps: maxSpeedMps,
            lastHeartRateBpm: lastHeartRateBpm,
            averageHeartRateBpm: averageHeartRateBpm,
            fixCount: fixCount,
            acceptedFixCount: acceptedFixCount,
            startedAt: startedAt,
            lastFixAt: lastFixAt
        )
    }
}
