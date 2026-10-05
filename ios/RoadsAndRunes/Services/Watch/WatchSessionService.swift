import Foundation
import RoadsAndRunesCore
import WatchConnectivity

/// iPhone side of the Watch link (docs/WATCH.md). Sends the route summary
/// once, throttled navigation updates, objective events, Journey's end and Next
/// up; receives pause/resume/end commands, heart-rate samples and start requests.
final class WatchSessionService: NSObject, WCSessionDelegate {
    var onCommand: ((WatchCommand) -> Void)?
    var onHeartRate: ((Int) -> Void)?
    /// A journey asked for on the wrist (0.7.3): plan it, start it without a tap,
    /// and say whether it started. Nil until the app wires its quick start; a
    /// request with nowhere to go is answered "not started".
    var onStartRequest: (@MainActor (QuickStart) async -> Bool)?

    private var lastUpdateSent: Date = .distantPast
    private var minimumInterval: TimeInterval = 2
    private(set) var isReachable = false

    /// The ride's last message, kept so Next up can go out beside it: the
    /// application context is replaced whole on every send.
    private var rideContext: [String: Any]?
    /// Next up as last sent (0.7.3).
    private(set) var idleInfo: WatchIdleInfo?
    /// The quests Next up offers, asked of the server at most every `questsKeptFor`.
    var idleQuests: [Quest] = []
    var idleQuestsFetchedAt: Date?
    static let questsKeptFor: TimeInterval = 300

    /// Whether a Watch with the app is there to tell: between rides nothing is
    /// fetched for it otherwise.
    var hasWatchApp: Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        return session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func configure(batteryMode: BatteryMode) {
        minimumInterval = BatteryPolicy.policy(for: batteryMode).watchUpdateInterval
    }

    func send(summary: WatchRouteSummary, units: Units) {
        guard var message = try? WatchMessages.routeSummary(summary) else { return }
        message["units"] = units.rawValue
        rideContext = message
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo(message)
        pushContext()
    }

    func send(update: WatchNavigationUpdate, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdateSent) >= minimumInterval else { return }
        lastUpdateSent = now
        guard let message = try? WatchMessages.navigationUpdate(update) else { return }
        // Kept whichever way it goes, so Next up never carries an older one with it.
        rideContext = message
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            pushContext()
        }
    }

    /// Next up for the Watch's idle screen and complication (0.7.3), whenever the
    /// World refreshes. The same again from the same day is not sent.
    func send(idleInfo info: WatchIdleInfo) {
        guard !info.says(sameAs: idleInfo) else { return }
        idleInfo = info
        pushContext()
    }

    /// The application context: the ride's last message with Next up beside it.
    /// A ride that ended leaves its last word there, so a Watch that was away
    /// still hears that it ended.
    private func pushContext() {
        let session = WCSession.default
        guard session.activationState == .activated,
              let context = try? WatchMessages.context(ride: rideContext, idle: idleInfo), !context.isEmpty else { return }
        try? session.updateApplicationContext(context)
    }

    /// What came of a start request: sent now if the Watch is there, else queued
    /// (the Watch lets an answer to an old question go).
    func send(startResult result: WatchStartResult) {
        guard let message = try? WatchMessages.startResult(result) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }

    /// A journey asked for on the wrist: handed to the quick start with `autoStart`,
    /// and the Watch told if it did not start. One heard too late starts nothing.
    @MainActor
    private func start(_ request: WatchStartRequest) {
        AppLog.watch.notice("watch_start_request kind=\(request.kind, privacy: .public)")
        guard let start = request.quickStart(defaultActivity: .ride), let onStartRequest else {
            send(startResult: WatchStartResult(requestId: request.id, started: false))
            return
        }
        Task { @MainActor in
            let started = await onStartRequest(start)
            self.send(startResult: WatchStartResult(requestId: request.id, started: started))
        }
    }

    func send(objectiveCompleted event: WatchObjectiveCompleted) {
        guard let message = try? WatchMessages.objectiveCompleted(event) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }

    /// Journey's end, once the server has counted the journey: sent now if the
    /// Watch is there, else queued for when it is (it lets one go once old).
    func send(journeyEnd end: WatchJourneyEnd) {
        guard let message = try? WatchMessages.journeyEnd(end) else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }

    /// A fight beat, felt on the wrist: dropped if the Watch is not there now. It
    /// is only true for a moment.
    func send(encounterBeat beat: WatchEncounterBeat) {
        guard let message = try? WatchMessages.encounterBeat(beat) else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    private func handle(_ message: [String: Any]) {
        guard let kind = WatchMessages.kind(of: message) else { return }
        switch kind {
        case .command:
            if let command = try? WatchMessages.command(from: message) {
                DispatchQueue.main.async { self.onCommand?(command) }
            }
        case .heartRate:
            if let sample = try? WatchMessages.heartRate(from: message) {
                DispatchQueue.main.async { self.onHeartRate?(sample.bpm) }
            }
        case .startRequest:
            if let request = try? WatchMessages.startRequest(from: message) {
                Task { @MainActor in self.start(request) }
            }
        default:
            break
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        isReachable = session.isReachable
        // Next up made before the link was up goes now (on main, where it is kept).
        guard activationState == .activated else { return }
        DispatchQueue.main.async { if self.idleInfo != nil { self.pushContext() } }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        isReachable = session.isReachable
        if !session.isReachable {
            AppLog.watch.notice("watch_disconnected")
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message)
        replyHandler(["ok": true])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }
}
