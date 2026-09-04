import Foundation

/// Records H3 cells entered during a ride, the distance ridden inside each
/// cell, and batches new cells for upload.
///
/// Not thread safe: the owner (typically the ride recording service) must
/// call it from a single queue or actor. It is a class so a long ride does not
/// copy its growing dictionaries on every fix.
public final class ExplorationRecorder {
    public static let defaultBatchSize = 50
    public static let defaultFlushInterval: TimeInterval = 60
    public static let maxAccuracyMeters = 50.0
    public static let maxPlausibleSpeedMps = 25.0

    public let indexing: CellIndexing
    public let resolution: Int
    /// Cells the server already knows as VISITED/EXPLORED before this ride.
    public let knownCells: Set<String>
    public let exploredThresholdMeters: Double
    public let batchSize: Int
    public let flushInterval: TimeInterval

    /// Cells in the order they were first entered.
    public private(set) var visitedCells: [String] = []
    public private(set) var distanceByCell: [String: Double] = [:]
    public private(set) var pendingUpload: [String] = []
    public private(set) var uploadedCells: Set<String> = []
    public private(set) var lastFlushAt: Date?
    /// Distance ridden inside cells that were not in `knownCells`.
    public private(set) var newTerritoryMeters: Double = 0
    public private(set) var currentCell: String?
    public private(set) var lastFix: LocationFix?
    private var visitedSet: Set<String> = []

    public init(
        indexing: CellIndexing,
        resolution: Int = ExplorationDefaults.h3Resolution,
        knownCells: Set<String> = [],
        exploredThresholdMeters: Double = ExplorationDefaults.exploredThresholdMeters,
        batchSize: Int = ExplorationRecorder.defaultBatchSize,
        flushInterval: TimeInterval = ExplorationRecorder.defaultFlushInterval
    ) {
        self.indexing = indexing
        self.resolution = resolution
        self.knownCells = knownCells
        self.exploredThresholdMeters = exploredThresholdMeters
        self.batchSize = batchSize
        self.flushInterval = flushInterval
    }

    /// Restores state persisted in an `ActiveRideState` after a crash.
    public func restore(visitedCells: [String], pendingUpload: [String], distanceByCell: [String: Double] = [:]) {
        for cell in visitedCells where !visitedSet.contains(cell) {
            visitedSet.insert(cell)
            self.visitedCells.append(cell)
        }
        for cell in pendingUpload where !self.pendingUpload.contains(cell) {
            self.pendingUpload.append(cell)
        }
        for (cell, distance) in distanceByCell {
            self.distanceByCell[cell, default: 0] += distance
        }
        lastFix = nil
    }

    public var newCellCount: Int { visitedCells.filter { !knownCells.contains($0) }.count }

    /// Records a fix. Returns the cells newly entered by this fix (empty or one).
    @discardableResult
    public func record(fix: LocationFix) -> [String] {
        if let accuracy = fix.horizontalAccuracy, accuracy > Self.maxAccuracyMeters {
            return []
        }
        let cell = indexing.cell(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, resolution: resolution)

        if let previous = lastFix {
            let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
            let step = GeoMath.distance(previous.coordinate, fix.coordinate)
            let plausible = dt <= 0 ? step < 1 : (step / dt) <= Self.maxPlausibleSpeedMps
            if plausible {
                distanceByCell[cell, default: 0] += step
                if !knownCells.contains(cell) {
                    newTerritoryMeters += step
                }
            }
        }
        lastFix = fix
        currentCell = cell
        if lastFlushAt == nil { lastFlushAt = fix.timestamp }

        guard !visitedSet.contains(cell) else { return [] }
        visitedSet.insert(cell)
        visitedCells.append(cell)
        distanceByCell[cell, default: 0] += 0
        pendingUpload.append(cell)
        return [cell]
    }

    /// Returns cells to upload when a batch is due: `batchSize` or more
    /// pending, or `flushInterval` elapsed since the last flush. `force`
    /// returns whatever is pending (use on pause/finish).
    public func takePendingBatch(now: Date, force: Bool = false) -> [String]? {
        guard !pendingUpload.isEmpty else { return nil }
        let elapsed = now.timeIntervalSince(lastFlushAt ?? now)
        guard force || pendingUpload.count >= batchSize || elapsed >= flushInterval else { return nil }
        let batch = pendingUpload
        pendingUpload = []
        lastFlushAt = now
        return batch
    }

    public func markUploaded(_ cells: [String]) {
        uploadedCells.formUnion(cells)
    }

    /// Put a failed batch back at the front of the queue.
    public func requeue(_ cells: [String]) {
        let existing = Set(pendingUpload)
        pendingUpload = cells.filter { !existing.contains($0) && !uploadedCells.contains($0) } + pendingUpload
    }

    public func distance(in cell: String) -> Double {
        distanceByCell[cell] ?? 0
    }

    public func localState(for cell: String) -> CellState {
        if visitedSet.contains(cell) {
            return distance(in: cell) >= exploredThresholdMeters ? .explored : .visited
        }
        return knownCells.contains(cell) ? .visited : .unseen
    }

    /// Local state of every cell touched this ride.
    public var localStates: [String: CellState] {
        var result: [String: CellState] = [:]
        for cell in visitedCells {
            result[cell] = localState(for: cell)
        }
        return result
    }
}
