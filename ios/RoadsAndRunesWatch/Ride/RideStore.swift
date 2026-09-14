import CoreLocation
import Foundation
import Observation
import RoadsAndRunesCore

/// Single source of truth for what the watch shows. Everything navigational
/// comes from the phone; the store never invents navigation. When the phone
/// drops, the last instruction stays on screen and `staleness` grows.
@MainActor
@Observable
final class RideStore {
    /// After this long without a phone message the navigation page shows a stale badge.
    static let staleAfter: TimeInterval = 60

    private(set) var summary: WatchRouteSummary?
    private(set) var update: WatchNavigationUpdate?
    /// Wall-clock time the last phone message (of any kind) was received.
    private(set) var lastUpdateAt: Date?
    var phoneReachable: Bool = false
    private(set) var pendingObjective: WatchObjectiveCompleted?
    /// Incremented for every objective completion so identical titles re-trigger the overlay.
    private(set) var objectiveToken: Int = 0
    private(set) var units: Units = .metric

    /// The route to draw on the map page, and the stops on it. Both come from the
    /// phone's route summary and stay put until the next ride.
    var routePath: [CLLocationCoordinate2D] {
        (summary?.path ?? []).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var stops: [WatchStop] { summary?.stops ?? [] }

    /// Where the phone last said the rider was; the map follows it rather than
    /// starting a second GPS on the wrist.
    var riderCoordinate: Coordinate? { update?.coordinate }

    /// Last non-nil instruction; survives updates whose instruction is nil and phone drops.
    private(set) var currentInstruction: Instruction?
    /// Distance to `currentInstruction` as last reported alongside a non-nil instruction.
    private(set) var currentDistanceToInstruction: Double?

    /// Heart rate measured by the watch workout (fresher than the phone's copy).
    var localHeartRate: Int?
    /// Set optimistically when the rider taps Pause/Resume; cleared by the next phone update.
    private(set) var optimisticPaused: Bool?

    /// Called on the main actor whenever the navigation state (or the presence of a route) changes.
    @ObservationIgnored var onRideStateChanged: ((NavigationState?) -> Void)?

    init() {}

    // MARK: - Derived state

    var state: NavigationState? { update?.state }

    var isRiding: Bool {
        guard let state = state else { return false }
        switch state {
        case .active, .paused, .offRoute, .rerouting:
            return true
        default:
            return false
        }
    }

    var isPaused: Bool {
        if let optimisticPaused = optimisticPaused { return optimisticPaused }
        return state == .paused
    }

    /// True while the ride clock should tick between phone updates.
    var isClockRunning: Bool {
        guard let state = state, !isPaused else { return false }
        return state.isRecording
    }

    var hasRoute: Bool { summary != nil }

    var formatter: UnitFormatter { UnitFormatter(units: units) }

    var heartRate: Int? { localHeartRate ?? update?.heartRate }

    var questTitle: String? { summary?.questTitle }

    /// The nearest thing in the world and how the fight is going, from the phone.
    var encounterLine: String? { update?.encounterLine }

    var objectiveTitle: String? {
        if let title = update?.objectiveTitle { return title }
        return summary?.objectives.first?.title
    }

    var objectiveDistanceMeters: Double? { update?.objectiveDistanceMeters }

    /// "then …" text: the phone's hint, else the next instruction from the summary.
    var nextInstructionText: String? {
        if let text = update?.nextInstructionText, !text.isEmpty { return text }
        guard let current = currentInstruction, let instructions = summary?.instructions else { return nil }
        let following = instructions.first { $0.index > current.index }
        guard let next = following, !next.text.isEmpty else { return nil }
        return next.text
    }

    // MARK: - Staleness

    /// Seconds since the last phone message; `.infinity` when nothing has arrived yet.
    func staleness(at now: Date = Date()) -> TimeInterval {
        guard let lastUpdateAt = lastUpdateAt else { return .infinity }
        return max(0, now.timeIntervalSince(lastUpdateAt))
    }

    var staleness: TimeInterval { staleness(at: Date()) }

    func isStale(at now: Date = Date()) -> Bool {
        staleness(at: now) > Self.staleAfter
    }

    /// Elapsed ride seconds, ticking locally between phone updates while riding.
    func elapsedSeconds(at now: Date = Date()) -> Double {
        guard let update = update else { return 0 }
        guard isClockRunning, let lastUpdateAt = lastUpdateAt else { return update.elapsedSeconds }
        return update.elapsedSeconds + max(0, now.timeIntervalSince(lastUpdateAt))
    }

    // MARK: - Inbound

    func apply(summary newSummary: WatchRouteSummary, receivedAt: Date = Date()) {
        summary = newSummary
        lastUpdateAt = receivedAt
        optimisticPaused = nil
        if currentInstruction == nil, let first = newSummary.instructions.first {
            currentInstruction = first
            currentDistanceToInstruction = first.distanceMeters
        }
        onRideStateChanged?(state)
    }

    func apply(update newUpdate: WatchNavigationUpdate, receivedAt: Date = Date()) {
        let previousState = update?.state
        update = newUpdate
        lastUpdateAt = receivedAt
        optimisticPaused = nil
        if let instruction = newUpdate.instruction {
            currentInstruction = instruction
            currentDistanceToInstruction = newUpdate.distanceToInstructionMeters
        }
        if newUpdate.state.isTerminal {
            summary = nil
            currentInstruction = nil
            currentDistanceToInstruction = nil
        }
        if previousState != newUpdate.state {
            onRideStateChanged?(newUpdate.state)
        }
    }

    func apply(objective: WatchObjectiveCompleted, receivedAt: Date = Date()) {
        lastUpdateAt = receivedAt
        pendingObjective = objective
        objectiveToken += 1
    }

    func clearObjective() {
        pendingObjective = nil
    }

    /// Accepts "METRIC" / "imperial" / nil; unknown values leave the current setting alone.
    func setUnits(raw: String?) {
        guard let raw = raw, !raw.isEmpty else { return }
        let parsed = Units.lenient(raw)
        guard parsed != .unknown else { return }
        units = parsed
    }

    // MARK: - Local commands

    func markPaused(_ paused: Bool) {
        optimisticPaused = paused
        onRideStateChanged?(paused ? .paused : .active)
    }

    /// The rider ended the ride from the watch; drop the route so the idle screen shows.
    func markEnded() {
        summary = nil
        currentInstruction = nil
        currentDistanceToInstruction = nil
        optimisticPaused = nil
        pendingObjective = nil
        onRideStateChanged?(.cancelled)
    }

    func reset() {
        summary = nil
        update = nil
        lastUpdateAt = nil
        pendingObjective = nil
        currentInstruction = nil
        currentDistanceToInstruction = nil
        optimisticPaused = nil
        localHeartRate = nil
    }
}
