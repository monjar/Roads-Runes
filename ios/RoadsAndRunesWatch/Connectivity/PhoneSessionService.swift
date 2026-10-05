import Foundation
import OSLog
import RoadsAndRunesCore
import WatchConnectivity

/// What the Watch needs of WatchConnectivity, so a test can stand in for the phone.
protocol PhoneLink: AnyObject {
    var isActivated: Bool { get }
    var isReachable: Bool { get }
    /// Sends now; `errorHandler` hears when it could not go.
    func send(_ message: [String: Any], errorHandler: ((Error) -> Void)?)
    /// Queues for when the phone is there.
    func queue(_ message: [String: Any])
}

/// The real link: the default `WCSession`.
final class SessionLink: PhoneLink {
    private var session: WCSession { WCSession.default }

    var isActivated: Bool { WCSession.isSupported() && session.activationState == .activated }
    var isReachable: Bool { session.isReachable }

    func send(_ message: [String: Any], errorHandler: ((Error) -> Void)?) {
        session.sendMessage(message, replyHandler: nil, errorHandler: errorHandler)
    }

    func queue(_ message: [String: Any]) {
        session.transferUserInfo(message)
    }
}

/// Receives route summaries, navigation updates, objective events, Journey's end and
/// Next up from the iPhone; sends commands, heart-rate samples and start requests
/// back. Keeps the last instruction when the phone drops and never invents navigation.
final class PhoneSessionService: NSObject, WCSessionDelegate {
    private let store: RideStore
    private let link: PhoneLink
    private let logger = Logger(subsystem: "com.roadsandrunes.app.watchkitapp", category: "connectivity")
    private var lastHeartRateSent: Date = .distantPast

    init(store: RideStore, link: PhoneLink = SessionLink()) {
        self.store = store
        self.link = link
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound

    func send(command: WatchCommand) {
        guard let message = try? WatchMessages.command(command) else { return }
        deliver(message, urgent: true)
    }

    func send(heartRate bpm: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastHeartRateSent) >= 5 else { return }
        lastHeartRateSent = now
        guard let message = try? WatchMessages.heartRate(WatchHeartRateSample(bpm: bpm, timestamp: now)) else { return }
        deliver(message, urgent: false)
    }

    /// Asks the phone to plan and start a journey (0.7.3), and shows "Planning…"
    /// until the ride comes. It goes only to a phone that is there now: one queued
    /// for later could start a ride long after the rider stopped waiting. False
    /// (and the plan failed) when it could not go.
    @MainActor
    @discardableResult
    func requestStart(_ request: WatchStartRequest, at now: Date = Date()) -> Bool {
        store.beginPlanning(request, at: now)
        guard link.isActivated, link.isReachable, let message = try? WatchMessages.startRequest(request) else {
            store.failPlanning(id: request.id)
            return false
        }
        link.send(message) { [weak self] error in
            self?.logger.warning("start_request_failed error=\(error.localizedDescription, privacy: .public)")
            Task { @MainActor in self?.store.failPlanning(id: request.id) }
        }
        return true
    }

    private func deliver(_ message: [String: Any], urgent: Bool) {
        guard link.isActivated else { return }
        if link.isReachable {
            link.send(message) { [logger, link] error in
                logger.warning("send_failed error=\(error.localizedDescription, privacy: .public)")
                if urgent { link.queue(message) }
            }
        } else if urgent {
            link.queue(message)
        }
    }

    // MARK: - Inbound

    /// One thing a message from the phone carries. An application context can
    /// carry two: the ride's last message and Next up beside it.
    enum Inbound {
        case summary(WatchRouteSummary)
        case update(WatchNavigationUpdate)
        case objective(WatchObjectiveCompleted)
        case beat(WatchEncounterBeat)
        case journeyEnd(WatchJourneyEnd)
        case startResult(WatchStartResult)
        case idle(WatchIdleInfo)
        case units(String)
    }

    /// What a message carries; a kind this build does not know, or cannot read, is passed over.
    static func read(_ message: [String: Any], logger: Logger? = nil) -> [Inbound] {
        var inbound: [Inbound] = []
        if let idle = WatchMessages.idleInfo(from: message) { inbound.append(.idle(idle)) }
        if let kind = WatchMessages.kind(of: message) {
            do {
                switch kind {
                case .routeSummary: inbound.append(.summary(try WatchMessages.routeSummary(from: message)))
                case .navigationUpdate: inbound.append(.update(try WatchMessages.navigationUpdate(from: message)))
                case .objectiveCompleted: inbound.append(.objective(try WatchMessages.objectiveCompleted(from: message)))
                case .encounterBeat: inbound.append(.beat(try WatchMessages.encounterBeat(from: message)))
                case .journeyEnd: inbound.append(.journeyEnd(try WatchMessages.journeyEnd(from: message)))
                case .startResult: inbound.append(.startResult(try WatchMessages.startResult(from: message)))
                case .command, .heartRate, .startRequest: break
                }
            } catch {
                logger?.error("decode_failed kind=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        if let units = message["units"] as? String { inbound.append(.units(units)) }
        return inbound
    }

    @MainActor
    func apply(_ inbound: [Inbound], receivedAt: Date = Date()) {
        for item in inbound {
            switch item {
            case .summary(let summary): store.apply(summary: summary, receivedAt: receivedAt)
            case .update(let update): store.apply(update: update, receivedAt: receivedAt)
            case .objective(let event): store.apply(objective: event, receivedAt: receivedAt)
            case .beat(let beat): TurnHaptics.play(beat.beat)
            case .journeyEnd(let end): store.apply(journeyEnd: end, receivedAt: receivedAt)
            case .startResult(let result): store.apply(startResult: result)
            case .idle(let idle): store.apply(idle: idle)
            case .units(let units): store.setUnits(raw: units)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        let receivedAt = Date()
        let inbound = Self.read(message, logger: logger)
        guard !inbound.isEmpty else { return }
        Task { @MainActor in self.apply(inbound, receivedAt: receivedAt) }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in self.store.phoneReachable = reachable }
        if let error {
            logger.error("activation_failed error=\(error.localizedDescription, privacy: .public)")
        }
        if !session.receivedApplicationContext.isEmpty {
            handle(session.receivedApplicationContext)
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        if !reachable {
            logger.notice("watch_disconnected")
        }
        Task { @MainActor in self.store.phoneReachable = reachable }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message)
        replyHandler(["ok": true])
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }
}
