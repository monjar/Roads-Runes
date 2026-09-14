import Foundation

/// Detects objective completion from ride telemetry. Photo/note objectives
/// and social/route objectives are never auto-completed; the server remains
/// authoritative and re-validates every event during post-processing.
public struct ObjectiveTracker: Sendable {
    public static let defaultRadiusMeters = 50.0
    public static let defaultCellRadiusMeters = 200.0
    public static let returnToStartRadiusMeters = 100.0
    public static let returnToStartMinimumDistanceMeters = 1000.0
    public static let requiredConsecutiveFixes = 2

    public struct CellTarget: Hashable, Sendable {
        public var h3: String
        public var coordinate: Coordinate

        public init(h3: String, coordinate: Coordinate) {
            self.h3 = h3
            self.coordinate = coordinate
        }
    }

    public let objectives: [Objective]
    public let start: Coordinate
    public private(set) var completedObjectiveIDs: Set<UUID> = []
    public private(set) var emittedEvents: [ObjectiveEvent] = []
    private var consecutiveHits: [UUID: Int] = [:]
    private var visitedCells: [UUID: Set<String>] = [:]
    private var cellTargets: [UUID: [CellTarget]] = [:]

    public init(objectives: [Objective], start: Coordinate) {
        self.objectives = objectives.sorted { $0.order < $1.order }
        self.start = start
        for objective in objectives {
            if objective.status == .completed {
                completedObjectiveIDs.insert(objective.id)
            }
            if objective.objectiveType == .visitMultipleLocations {
                cellTargets[objective.id] = Self.cells(from: objective)
            }
        }
    }

    /// Cells decoded from `extra["cells"]` (`[{h3, latitude, longitude}]`).
    public static func cells(from objective: Objective) -> [CellTarget] {
        guard let array = objective.extra?["cells"]?.arrayValue else { return [] }
        return array.compactMap { value in
            guard let h3 = value["h3"]?.stringValue,
                  let latitude = value["latitude"]?.doubleValue,
                  let longitude = value["longitude"]?.doubleValue else { return nil }
            return CellTarget(h3: h3, coordinate: Coordinate(latitude: latitude, longitude: longitude))
        }
    }

    public var pendingObjectives: [Objective] {
        objectives.filter { !completedObjectiveIDs.contains($0.id) }
    }

    /// Cells already visited for a VISIT_MULTIPLE_LOCATIONS objective.
    public func visitedCells(for objectiveID: UUID) -> Set<String> {
        visitedCells[objectiveID] ?? []
    }

    /// Feed the latest fix and cumulative ride totals. Returns completion
    /// events for objectives that just completed (each at most once).
    public mutating func update(
        position: Coordinate,
        distanceMeters: Double,
        elevationGainMeters: Double,
        newTerritoryMeters: Double,
        elapsedSeconds: Double = 0,
        timestamp: Date
    ) -> [ObjectiveEvent] {
        var events: [ObjectiveEvent] = []
        for objective in objectives where !completedObjectiveIDs.contains(objective.id) {
            var completed = false
            var value: Double?
            switch objective.objectiveType {
            case .visitLocation, .visitPOI, .visitRegion:
                completed = checkProximity(objective, position: position)
            case .visitMultipleLocations:
                completed = checkCells(objective, position: position)
            case .completeDistance:
                if let target = objective.targetMeters, distanceMeters >= target {
                    completed = true
                    value = distanceMeters
                }
            case .exploreNewRoads, .exploreDistance:
                if let target = objective.targetMeters, newTerritoryMeters >= target {
                    completed = true
                    value = newTerritoryMeters
                }
            case .reachElevation, .completeClimb:
                if let target = objective.targetElevationMeters ?? objective.targetMeters, elevationGainMeters >= target {
                    completed = true
                    value = elevationGainMeters
                }
            case .returnToStart:
                let anchor = objective.coordinate ?? start
                let radius = objective.radiusMeters ?? Self.returnToStartRadiusMeters
                if distanceMeters >= Self.returnToStartMinimumDistanceMeters,
                   GeoMath.distance(position, anchor) <= radius {
                    completed = true
                    value = distanceMeters
                }
            case .rideDuration:
                let minutes = elapsedSeconds / 60
                if minutes >= objective.progress.target, objective.progress.target > 0 {
                    completed = true
                    value = minutes
                }
            case .sustainSpeed:
                // Average over the ride so far; the server decides finally, at the end.
                let speed = elapsedSeconds > 0 ? (distanceMeters / 1000) / (elapsedSeconds / 3600) : 0
                if speed >= objective.progress.target, objective.progress.target > 0,
                   distanceMeters >= (objective.targetMeters ?? 0) {
                    completed = true
                    value = speed
                }
            case .photoLocation, .writeNote, .completeWithFriend, .completeRoute, .unknown:
                completed = false  // these need the rider to act, or the server to decide
            case .slayMonster, .openChest, .collect:
                completed = false  // the encounter tracker marks these when the world object is claimed
            }
            if completed {
                completedObjectiveIDs.insert(objective.id)
                let event = ObjectiveEvent(objectiveId: objective.id, occurredAt: timestamp, coordinate: position, value: value)
                events.append(event)
                emittedEvents.append(event)
            }
        }
        return events
    }

    /// Manually mark an objective complete (e.g. photo taken, note written).
    /// Returns the event to send, or nil if it was already complete.
    public mutating func markCompleted(_ objectiveID: UUID, at position: Coordinate?, timestamp: Date) -> ObjectiveEvent? {
        guard !completedObjectiveIDs.contains(objectiveID) else { return nil }
        completedObjectiveIDs.insert(objectiveID)
        let event = ObjectiveEvent(objectiveId: objectiveID, occurredAt: timestamp, coordinate: position, value: nil)
        emittedEvents.append(event)
        return event
    }

    /// Live progress for UI (`current`/`target`).
    public func progress(for objective: Objective, distanceMeters: Double, elevationGainMeters: Double, newTerritoryMeters: Double, elapsedSeconds: Double = 0) -> ObjectiveProgress {
        if completedObjectiveIDs.contains(objective.id) {
            return ObjectiveProgress(current: objective.progress.target, target: objective.progress.target)
        }
        switch objective.objectiveType {
        case .completeDistance, .returnToStart:
            return ObjectiveProgress(current: distanceMeters, target: objective.targetMeters ?? objective.progress.target)
        case .exploreNewRoads, .exploreDistance:
            return ObjectiveProgress(current: newTerritoryMeters, target: objective.targetMeters ?? objective.progress.target)
        case .reachElevation, .completeClimb:
            return ObjectiveProgress(current: elevationGainMeters, target: objective.targetElevationMeters ?? objective.progress.target)
        case .visitMultipleLocations:
            let total = Double(cellTargets[objective.id]?.count ?? 0)
            return ObjectiveProgress(current: Double(visitedCells[objective.id]?.count ?? 0), target: total > 0 ? total : objective.progress.target)
        case .rideDuration:
            return ObjectiveProgress(current: elapsedSeconds / 60, target: objective.progress.target)
        case .sustainSpeed:
            let speed = elapsedSeconds > 0 ? (distanceMeters / 1000) / (elapsedSeconds / 3600) : 0
            return ObjectiveProgress(current: speed, target: objective.progress.target)
        default:
            return objective.progress
        }
    }

    // MARK: Private

    private mutating func checkProximity(_ objective: Objective, position: Coordinate) -> Bool {
        guard let target = objective.coordinate else { return false }
        let radius = objective.radiusMeters ?? Self.defaultRadiusMeters
        if GeoMath.distance(position, target) <= radius {
            let hits = (consecutiveHits[objective.id] ?? 0) + 1
            consecutiveHits[objective.id] = hits
            return hits >= Self.requiredConsecutiveFixes
        }
        consecutiveHits[objective.id] = 0
        return false
    }

    private mutating func checkCells(_ objective: Objective, position: Coordinate) -> Bool {
        guard let targets = cellTargets[objective.id], !targets.isEmpty else { return false }
        let radius = objective.radiusMeters ?? Self.defaultCellRadiusMeters
        var visited = visitedCells[objective.id] ?? []
        for target in targets where !visited.contains(target.h3) {
            if GeoMath.distance(position, target.coordinate) <= radius {
                visited.insert(target.h3)
            }
        }
        visitedCells[objective.id] = visited
        return visited.count >= targets.count
    }
}
