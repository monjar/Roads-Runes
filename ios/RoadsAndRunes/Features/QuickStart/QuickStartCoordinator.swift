import Foundation
import Observation
import RoadsAndRunesCore

/// What came of a quick start: a route waiting on the Start button, a journey
/// under way, or a plain reason it could not be planned.
enum QuickStartOutcome: Equatable, Sendable {
    case ready
    case started
    case failed(String)
}

/// Turns a `QuickStart` (0.7.3) — from Siri and Shortcuts, the Action Button, a
/// widget's link, the Quests tab or the Watch — into a planned route with Start
/// ready on screen. A start asked for on the wrist (`autoStart`) begins the
/// journey without a tap: the rider already said so.
///
///     QuickStartCoordinator.shared.handle(.sealed(minutes: 40), autoStart: false)
///     let outcome = await QuickStartCoordinator.shared.handle(.bounty, autoStart: true).value
///
/// A start asked for before the app has signed in or found where it is waits for
/// both, then plans. A newer start replaces one still planning.
@MainActor
@Observable
final class QuickStartCoordinator {
    static let shared = QuickStartCoordinator()

    enum Phase: Equatable {
        case idle
        case planning
        case ready
        case failed(String)
    }

    /// What a plan came to.
    struct Plan: Equatable {
        var route: RouteOption
        var quest: Quest?
        var activity: Activity
        var title: String?
        var destination: Place?
        var quarryId: UUID?
    }

    private(set) var phase: Phase = .idle
    private(set) var request: QuickStart?
    private(set) var plan: Plan?
    private(set) var isStarting = false
    /// Whether the route card is on screen.
    var isPresented = false

    var route: RouteOption? { plan?.route }
    var quest: Quest? { plan?.quest }
    var activity: Activity { plan?.activity ?? container?.session.defaultActivity ?? .ride }

    @ObservationIgnored private weak var container: AppContainer?
    @ObservationIgnored private var waiting: [(start: QuickStart, autoStart: Bool, done: CheckedContinuation<QuickStartOutcome, Never>)] = []
    @ObservationIgnored private var bikeId: UUID?
    /// Which request is the latest: an older one finishing late changes nothing.
    @ObservationIgnored private var generation = 0
    /// How long a start waits for a sign-in and a first fix.
    @ObservationIgnored var patience: Duration = .seconds(20)
    /// Where the rider is now; a test stands in for the GPS here.
    @ObservationIgnored var locate: (AppContainer) -> Coordinate? = { $0.location.lastFix?.coordinate }

    init(container: AppContainer? = nil) {
        self.container = container
    }

    /// The app's container, once it exists. A start that came first is planned now.
    func attach(_ container: AppContainer) {
        self.container = container
        let queued = waiting
        waiting = []
        for item in queued {
            Task { item.done.resume(returning: await run(item.start, autoStart: item.autoStart)) }
        }
    }

    /// Plans `start` and shows its route ready to Start; with `autoStart`, starts it.
    /// The returned task says how it went, for a caller that wants to know (the Watch).
    @discardableResult
    func handle(_ start: QuickStart, autoStart: Bool = false) -> Task<QuickStartOutcome, Never> {
        Task { await run(start, autoStart: autoStart) }
    }

    func run(_ start: QuickStart, autoStart: Bool) async -> QuickStartOutcome {
        guard let container else {
            // Opened by an intent before the container was made: wait for `attach`.
            return await withCheckedContinuation { continuation in
                waiting.append((start, autoStart, continuation))
            }
        }
        guard !container.rideRecorder.isActive else { return .failed("A journey is already under way. End it first.") }
        generation += 1
        let mine = generation
        request = start
        plan = nil
        phase = .planning
        isPresented = true
        do {
            guard await ready(container) else { throw QuickStartError.notSignedIn }
            guard let origin = await origin(container) else { throw QuickStartError.noLocation }
            let planned = try await makePlan(start, from: origin, container: container)
            guard mine == generation else { return .failed(Self.failedLine) }
            plan = planned
            phase = .ready
            container.analytics.track(.routeGenerated, properties: ["count": "1", "from": "quickStart"])
            if autoStart {
                return await startRide() ? .started : .failed(errorLine)
            }
            return .ready
        } catch {
            guard mine == generation else { return .failed(Self.failedLine) }
            let line = (error as? QuickStartError)?.line ?? error.localizedDescription
            phase = .failed(line)
            return .failed(line)
        }
    }

    /// Downloads the route, closes the card and starts the journey.
    func startRide() async -> Bool {
        guard let container, let plan, !isStarting else { return false }
        isStarting = true
        defer { isStarting = false }
        do {
            var quest = plan.quest
            if let current = quest, current.status == .available {
                quest = try await container.api.acceptQuest(id: current.id)
            }
            let package = try await container.api.routePackage(id: plan.route.id)
            container.analytics.track(.routeSelected, properties: ["routeId": plan.route.id.uuidString, "label": plan.route.label, "from": "quickStart"])
            if let quest { container.analytics.track(.questStarted, properties: ["questId": quest.id.uuidString]) }
            // The card goes first: the ride's own screen cannot rise over it.
            isPresented = false
            // A loop or the bounty is no quest, whatever the package carries; a quest's own is the one planned.
            await container.rideRecorder.start(
                package: package, quest: quest, bikeId: plan.activity == .ride ? bikeId : nil,
                title: quest == nil ? plan.title : nil, activity: plan.activity, quarryId: plan.quarryId
            )
            phase = .idle
            self.plan = nil
            request = nil
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            isPresented = true
            return false
        }
    }

    func dismiss() {
        generation += 1
        isPresented = false
        phase = .idle
        request = nil
        plan = nil
    }

    var errorLine: String {
        if case .failed(let line) = phase { return line }
        return Self.failedLine
    }

    static let failedLine = "Couldn't plan that. Try planning it here."

    // MARK: Planning

    private func makePlan(_ start: QuickStart, from origin: Coordinate, container: AppContainer) async throws -> Plan {
        let usual = container.session.defaultActivity
        bikeId = await defaultBike(container)
        switch start {
        case .loop(let minutes, let asked):
            let activity = asked == .unknown ? usual : asked
            let response = try await container.api.generateRoutes(RouteGenerateRequest(
                origin: origin, bikeId: activity == .ride ? bikeId : nil,
                distanceTargetKm: QuickStart.loopDistanceKm(minutes: minutes, activity: activity), loop: true,
                activity: activity
            ))
            guard let best = Self.pick(response.alternatives) else { throw QuickStartError.noRoute }
            return Plan(route: best, activity: activity, title: "\(minutes)-minute loop")
        case .bounty:
            guard let bounty = try await container.api.bounty() else { throw QuickStartError.noBounty }
            let response = try await container.api.generateRoutes(RouteGenerateRequest(
                origin: origin, destination: bounty.coordinate, bikeId: usual == .ride ? bikeId : nil, loop: false, activity: usual
            ))
            guard let best = Self.pick(response.alternatives) else { throw QuickStartError.noRoute }
            return Plan(route: best, activity: usual, title: "\(usual.verb) to \(bounty.name)",
                        destination: WorldViewModel.place(for: bounty), quarryId: bounty.kind == .monster ? bounty.id : nil)
        case .sealed(let minutes):
            let sealed = try await container.api.sealedQuest(SealedQuestRequest(minutes: minutes, at: origin, activity: usual))
            let route = try await container.api.questRoute(id: sealed.id, from: origin)
            return Plan(route: route, quest: sealed, activity: Self.activity(of: sealed, or: usual))
        case .quest(let id):
            let found = try await container.api.quest(id: id)
            guard [.available, .accepted, .active].contains(found.status) else { throw QuickStartError.questOver }
            let route = try await container.api.questRoute(id: id, from: origin)
            return Plan(route: route, quest: found, activity: Self.activity(of: found, or: usual))
        }
    }

    /// The way that does what was asked, else the best-scoring one.
    static func pick(_ alternatives: [RouteOption]) -> RouteOption? {
        alternatives.first { $0.label == "As asked" }
            ?? alternatives.first { $0.label == "Adventure" }
            ?? alternatives.max { $0.score < $1.score }
    }

    private static func activity(of quest: Quest, or usual: Activity) -> Activity {
        quest.activity.flatMap { $0 == .unknown ? nil : $0 } ?? usual
    }

    private func defaultBike(_ container: AppContainer) async -> UUID? {
        let bikes = (try? await container.api.bikes()) ?? []
        return (bikes.first { $0.isDefault } ?? bikes.first)?.id
    }

    /// Signed in with a character, or given up on after `patience`.
    private func ready(_ container: AppContainer) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: patience)
        while clock.now < deadline {
            let session = container.session
            if session.state == .ready, !session.isOnboarding { return true }
            if session.state == .signedOut || session.state == .needsCharacter { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Where the rider is: the last fix, or the first one to arrive.
    private func origin(_ container: AppContainer) async -> Coordinate? {
        if let fix = locate(container) { return fix }
        container.location.requestWhenInUse()
        if !container.rideRecorder.isActive { container.location.startBrowsing() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: patience)
        while clock.now < deadline {
            if let fix = locate(container) { return fix }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }
}

/// Why a quick start could not be planned, said plainly (docs/VOICE.md rule 7).
enum QuickStartError: Error, Equatable {
    case notSignedIn
    case noLocation
    case noRoute
    case noBounty
    case questOver

    var line: String {
        switch self {
        case .notSignedIn: return "Sign in first, then try again."
        case .noLocation: return "Can't find your location yet. Try again in a moment."
        case .noRoute: return "Couldn't find a route from here. Try planning one."
        case .noBounty: return "No bounty out right now. A new one comes at dawn."
        case .questOver: return "That quest is over. Pick another on the board."
        }
    }
}
