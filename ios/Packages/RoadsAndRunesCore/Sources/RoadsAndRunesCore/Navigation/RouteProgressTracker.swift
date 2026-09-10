import Foundation

/// Snapshot returned by `RouteProgressTracker.update(position:)`.
public struct ProgressUpdate: Hashable, Sendable {
    public var distanceAlongRoute: Double
    public var distanceRemaining: Double
    public var nearestSegmentIndex: Int
    public var crossTrackDistance: Double
    public var snappedPosition: Coordinate
    public var nextInstruction: Instruction?
    public var distanceToNextInstruction: Double?
    public var isOffRoute: Bool
    public var fractionComplete: Double

    public init(distanceAlongRoute: Double, distanceRemaining: Double, nearestSegmentIndex: Int, crossTrackDistance: Double, snappedPosition: Coordinate, nextInstruction: Instruction?, distanceToNextInstruction: Double?, isOffRoute: Bool, fractionComplete: Double) {
        self.distanceAlongRoute = distanceAlongRoute
        self.distanceRemaining = distanceRemaining
        self.nearestSegmentIndex = nearestSegmentIndex
        self.crossTrackDistance = crossTrackDistance
        self.snappedPosition = snappedPosition
        self.nextInstruction = nextInstruction
        self.distanceToNextInstruction = distanceToNextInstruction
        self.isOffRoute = isOffRoute
        self.fractionComplete = fractionComplete
    }
}

/// Matches GPS fixes to a route polyline and tracks progress with value
/// semantics (copy it into a persisted snapshot at any time).
///
/// Off-route hysteresis: more than `offRouteThresholdMeters` cross-track for
/// `offRouteConsecutiveUpdates` consecutive fixes flips to off-route; a fix
/// closer than `onRouteThresholdMeters` flips back.
///
/// Matching searches a window of segments ahead of the last match first so
/// loops that cross or retrace themselves do not jump ahead; only when no
/// segment in the window is within the off-route threshold does it fall back
/// to a global search.
public struct RouteProgressTracker: Hashable, Sendable {
    public static let offRouteThresholdMeters = 40.0
    public static let onRouteThresholdMeters = 20.0
    public static let offRouteConsecutiveUpdates = 3
    public static let searchWindowSegments = 60

    public let path: [Coordinate]
    public let instructions: [Instruction]
    public let totalDistance: Double
    private let cumulative: [Double]

    public private(set) var lastSegmentIndex: Int = 0
    public private(set) var isOffRoute: Bool = false
    public private(set) var lastUpdate: ProgressUpdate?
    private var consecutiveFarFixes = 0

    /// - Parameter coordinates: GeoJSON-ordered `[lon, lat(, ele)]` arrays as delivered in `RouteOption.coordinates`.
    public init(coordinates: [[Double]], instructions: [Instruction]) {
        self.init(path: coordinates.compactMap { Coordinate(geoJSON: $0) }, instructions: instructions)
    }

    public init(route: RouteOption) {
        self.init(coordinates: route.coordinates, instructions: route.instructions)
    }

    public init(path: [Coordinate], instructions: [Instruction]) {
        self.path = path
        self.instructions = instructions.sorted { $0.coordinateIndex < $1.coordinateIndex }
        self.cumulative = GeoMath.cumulativeDistances(path)
        self.totalDistance = cumulative.last ?? 0
    }

    public var segmentCount: Int { max(0, path.count - 1) }

    /// Restart matching from a segment (e.g. after a reroute replaces the tracker).
    public mutating func reset(toSegment index: Int = 0) {
        lastSegmentIndex = min(max(0, index), max(0, segmentCount - 1))
        consecutiveFarFixes = 0
        isOffRoute = false
        lastUpdate = nil
    }

    public mutating func update(position: Coordinate) -> ProgressUpdate {
        guard segmentCount > 0 else {
            let update = ProgressUpdate(
                distanceAlongRoute: 0, distanceRemaining: 0, nearestSegmentIndex: 0,
                crossTrackDistance: path.first.map { GeoMath.distance(position, $0) } ?? 0,
                snappedPosition: path.first ?? position, nextInstruction: nil,
                distanceToNextInstruction: nil, isOffRoute: false, fractionComplete: 0
            )
            lastUpdate = update
            return update
        }

        let windowEnd = min(segmentCount, lastSegmentIndex + Self.searchWindowSegments)
        var match = bestMatch(in: lastSegmentIndex..<windowEnd, position: position)
        if match.projection.distanceMeters > Self.offRouteThresholdMeters {
            let global = bestMatch(in: 0..<segmentCount, position: position)
            if global.projection.distanceMeters <= Self.offRouteThresholdMeters {
                match = global
            }
        }

        lastSegmentIndex = match.index
        let crossTrack = match.projection.distanceMeters
        if crossTrack > Self.offRouteThresholdMeters {
            consecutiveFarFixes += 1
            if consecutiveFarFixes >= Self.offRouteConsecutiveUpdates {
                isOffRoute = true
            }
        } else {
            consecutiveFarFixes = 0
            if crossTrack < Self.onRouteThresholdMeters {
                isOffRoute = false
            }
        }

        let segmentLength = cumulative[match.index + 1] - cumulative[match.index]
        let along = cumulative[match.index] + match.projection.fraction * segmentLength
        let remaining = max(0, totalDistance - along)

        var next: Instruction?
        var distanceToNext: Double?
        if let instruction = instructions.first(where: { $0.coordinateIndex > match.index }) {
            next = instruction
            let vertex = min(max(0, instruction.coordinateIndex), cumulative.count - 1)
            distanceToNext = max(0, cumulative[vertex] - along)
        }

        let update = ProgressUpdate(
            distanceAlongRoute: along,
            distanceRemaining: remaining,
            nearestSegmentIndex: match.index,
            crossTrackDistance: crossTrack,
            snappedPosition: match.projection.point,
            nextInstruction: next,
            distanceToNextInstruction: distanceToNext,
            isOffRoute: isOffRoute,
            fractionComplete: totalDistance > 0 ? min(1, along / totalDistance) : 0
        )
        lastUpdate = update
        return update
    }

    private struct Match {
        var index: Int
        var projection: GeoMath.SegmentProjection
    }

    private func bestMatch(in range: Range<Int>, position: Coordinate) -> Match {
        var best: Match?
        for index in range {
            let projection = GeoMath.project(position, ontoSegment: path[index], path[index + 1])
            if let current = best {
                if projection.distanceMeters < current.projection.distanceMeters {
                    best = Match(index: index, projection: projection)
                }
            } else {
                best = Match(index: index, projection: projection)
            }
        }
        if let best = best { return best }
        let index = min(max(0, range.lowerBound), segmentCount - 1)
        return Match(index: index, projection: GeoMath.project(position, ontoSegment: path[index], path[index + 1]))
    }
}
