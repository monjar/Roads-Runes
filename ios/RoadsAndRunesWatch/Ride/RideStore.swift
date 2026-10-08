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
    /// The turn to be felt on the wrist, and a count so the same cue twice still taps twice.
    private(set) var turnCue: TurnCue?
    private(set) var turnCueToken: Int = 0
    @ObservationIgnored private var turnCues = TurnCueTracker()
    private(set) var units: Units = .metric

    /// The route to draw on the map page, and the stops on it. Both come from the
    /// phone's route summary and stay put until the next ride.
    var routePath: [CLLocationCoordinate2D] {
        (summary?.path ?? []).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var stops: [WatchStop] { summary?.stops ?? [] }

    /// The game near the route (creatures, chests, rune stones, objective places),
    /// less what has been opened, defeated or done since. None from an older phone.
    var worldMarks: [WatchWorldMark] {
        (summary?.worldMarks ?? []).filter { !goneMarkIds.contains($0.id) }
    }

    /// Everything the phone has said is gone on this journey; it only grows until the journey ends.
    private(set) var goneMarkIds: Set<UUID> = []

    /// The fight for the Quest page: the quarry, else the nearest creature being
    /// fought; a legend's in its phases (0.8.0). None from an older phone, or when
    /// nothing is being fought.
    var fight: WatchFight? { update?.fight }

    /// Journey's end, from the phone once the server has counted it; shown on the
    /// idle face until Done. A count so the same totals twice still show twice.
    private(set) var journeyEnd: WatchJourneyEnd?
    private(set) var journeyEndToken: Int = 0
    /// Heard of later than this after the journey ended, Journey's end is let go.
    static let journeyEndKeptFor: TimeInterval = 3600

    /// Which district the rider is in, named once a journey at a standstill (0.9.0).
    private var districts = DistrictNaming()

    /// Ride, run or walk, as the phone started it; nil before a route summary (or from an older phone).
    var activity: Activity? { summary?.activity.flatMap(Activity.init(rawValue:)) }

    /// "ride", "run" or "walk", so a run is never called a ride on the wrist.
    var journey: String { LoreCopy.journey(activity) }

    /// Where the phone last said the rider was; the map follows it rather than
    /// starting a second GPS on the wrist.
    var riderCoordinate: Coordinate? { update?.coordinate }

    /// Which way the rider is heading: the phone's course, or, from an older phone
    /// that sends none, worked out here from the positions it sends.
    var riderCourse: Double? { update?.courseDegrees ?? courseFromPositions.course }
    @ObservationIgnored private var courseFromPositions = CourseTracker()

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

    // MARK: Between rides (0.7.3)

    /// Next up from the phone, for the idle screen and the complication. Nil from
    /// an older phone, which cannot start a journey from the wrist either.
    private(set) var idle: WatchIdleInfo?

    /// A journey asked for on the wrist: planning until the phone's route summary
    /// arrives, failed when the phone says so, the message cannot go, or it takes
    /// longer than `planningTimeout`.
    enum Planning: Equatable {
        case planning(id: UUID, since: Date)
        case failed(id: UUID)
    }

    private(set) var planning: Planning?
    /// Planning a route (and a sealed quest) takes seconds; this long means it is not coming.
    static let planningTimeout: TimeInterval = 75

    /// Called on the main actor when what the complication shows may have changed:
    /// Next up, or the quarry of the journey under way.
    @ObservationIgnored var onFaceChanged: (() -> Void)?

    /// The creature (or, from 0.8.0, the legend) the journey under way was planned for, while it stands.
    var quarry: WatchQuarry? {
        guard hasRoute else { return nil }
        return worldMarks.first { $0.isQuarry && ($0.kind == WatchWorldMark.monster || $0.isLegend) }.map(WatchQuarry.init(mark:))
    }

    var isPlanning: Bool {
        if case .planning = planning { return true }
        return false
    }

    var planningFailed: Bool {
        if case .failed = planning { return true }
        return false
    }

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

    /// The district to name at `now` (0.9.0): one new to this journey, while the
    /// rider stands (Core `Stillness`, from the speeds the phone sends), never while
    /// moving, and not on what may be old news.
    func districtLine(at now: Date = Date()) -> String? {
        guard isRiding, !isStale(at: now) else { return nil }
        return districts.line(at: now)
    }

    /// Elapsed ride seconds, ticking locally between phone updates while riding.
    func elapsedSeconds(at now: Date = Date()) -> Double {
        guard let update = update else { return 0 }
        guard isClockRunning, let lastUpdateAt = lastUpdateAt else { return update.elapsedSeconds }
        return update.elapsedSeconds + max(0, now.timeIntervalSince(lastUpdateAt))
    }

    // MARK: - Inbound

    func apply(summary newSummary: WatchRouteSummary, receivedAt: Date = Date()) {
        // A new route (a reroute included) numbers its turns from the start again.
        if newSummary.instructions != summary?.instructions { turnCues.reset() }
        // A new journey, not a reroute of this one: the last one's ends are old news.
        if summary == nil {
            goneMarkIds = []
            journeyEnd = nil
            districts = DistrictNaming()
        }
        summary = newSummary
        lastUpdateAt = receivedAt
        optimisticPaused = nil
        // The ride asked for on the wrist has come.
        planning = nil
        if currentInstruction == nil, let first = newSummary.instructions.first {
            currentInstruction = first
            currentDistanceToInstruction = first.distanceMeters
        }
        onRideStateChanged?(state)
        onFaceChanged?()
    }

    func apply(update newUpdate: WatchNavigationUpdate, receivedAt: Date = Date()) {
        let previousState = update?.state
        if let here = newUpdate.coordinate { courseFromPositions.update(here) }
        update = newUpdate
        lastUpdateAt = receivedAt
        optimisticPaused = nil
        if let instruction = newUpdate.instruction {
            currentInstruction = instruction
            currentDistanceToInstruction = newUpdate.distanceToInstructionMeters
        }
        if let gone = newUpdate.goneMarkIds { goneMarkIds.formUnion(gone) }
        districts.update(district: newUpdate.districtName, speedMps: newUpdate.speedMps, at: receivedAt)
        if newUpdate.state == .active, let cue = turnCues.update(instruction: newUpdate.instruction, distanceMeters: newUpdate.distanceToInstructionMeters) {
            turnCue = cue
            turnCueToken += 1
        }
        if newUpdate.state.isTerminal {
            courseFromPositions.reset()
            goneMarkIds = []
            districts = DistrictNaming()
            summary = nil
            currentInstruction = nil
            currentDistanceToInstruction = nil
        }
        if previousState != newUpdate.state {
            onRideStateChanged?(newUpdate.state)
        }
        if newUpdate.goneMarkIds != nil || newUpdate.state.isTerminal { onFaceChanged?() }
    }

    func apply(objective: WatchObjectiveCompleted, receivedAt: Date = Date()) {
        lastUpdateAt = receivedAt
        pendingObjective = objective
        objectiveToken += 1
    }

    func clearObjective() {
        pendingObjective = nil
    }

    /// Journey's end has come. Let go when it is old: heard of long after, or
    /// ended before the journey now under way began.
    func apply(journeyEnd end: WatchJourneyEnd, receivedAt: Date = Date()) {
        if let ended = end.endedAt {
            if receivedAt.timeIntervalSince(ended) > Self.journeyEndKeptFor { return }
            if isRiding, ended < receivedAt.addingTimeInterval(-elapsedSeconds(at: receivedAt) - 60) { return }
        }
        journeyEnd = end
        journeyEndToken += 1
    }

    /// Done: back to the idle face.
    func dismissJourneyEnd() {
        journeyEnd = nil
    }

    // MARK: - Next up and starting from the wrist (0.7.3)

    /// Next up from the phone. One made before the one already here (heard late) is let go.
    func apply(idle newIdle: WatchIdleInfo) {
        if let have = idle?.updatedAt, let made = newIdle.updatedAt, made < have { return }
        idle = newIdle
        setUnits(raw: newIdle.units)
        onFaceChanged?()
    }

    /// Next up as the app group kept it, for the idle screen before the phone speaks.
    func restore(idle kept: WatchIdleInfo?) {
        guard idle == nil, let kept else { return }
        idle = kept
        setUnits(raw: kept.units)
    }

    /// "Planning…" until the ride comes.
    func beginPlanning(_ request: WatchStartRequest, at now: Date = Date()) {
        planning = .planning(id: request.id, since: now)
    }

    /// The phone's answer. Only "it did not start" changes anything: a start shows
    /// itself with the route summary.
    func apply(startResult result: WatchStartResult) {
        guard case let .planning(id, _) = planning, result.requestId == nil || result.requestId == id else { return }
        if !result.started { planning = .failed(id: id) }
    }

    /// The request could not reach the phone.
    func failPlanning(id: UUID) {
        guard case let .planning(current, _) = planning, current == id else { return }
        planning = .failed(id: id)
    }

    /// Gives up on a plan that has taken longer than `planningTimeout` by `now`.
    func expirePlanning(at now: Date = Date()) {
        guard case let .planning(id, since) = planning, now.timeIntervalSince(since) >= Self.planningTimeout else { return }
        planning = .failed(id: id)
    }

    func dismissPlanning() {
        planning = nil
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
        goneMarkIds = []
        districts = DistrictNaming()
        currentInstruction = nil
        currentDistanceToInstruction = nil
        optimisticPaused = nil
        pendingObjective = nil
        onRideStateChanged?(.cancelled)
        onFaceChanged?()
    }

    func reset() {
        courseFromPositions.reset()
        summary = nil
        goneMarkIds = []
        districts = DistrictNaming()
        journeyEnd = nil
        update = nil
        lastUpdateAt = nil
        pendingObjective = nil
        currentInstruction = nil
        currentDistanceToInstruction = nil
        optimisticPaused = nil
        localHeartRate = nil
    }
}
