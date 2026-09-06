import Foundation
import RoadsAndRunesCore
import WatchConnectivity

/// iPhone side of the Watch link (docs/WATCH.md). Sends the route summary
/// once, throttled navigation updates, and objective events; receives
/// pause/resume/end commands and heart-rate samples.
final class WatchSessionService: NSObject, WCSessionDelegate {
    var onCommand: ((WatchCommand) -> Void)?
    var onHeartRate: ((Int) -> Void)?

    private var lastUpdateSent: Date = .distantPast
    private var minimumInterval: TimeInterval = 2
    private(set) var isReachable = false

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
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.transferUserInfo(message)
        try? session.updateApplicationContext(message)
    }

    func send(update: WatchNavigationUpdate, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdateSent) >= minimumInterval else { return }
        lastUpdateSent = now
        guard let message = try? WatchMessages.navigationUpdate(update) else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil, errorHandler: nil)
        } else {
            try? session.updateApplicationContext(message)
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
        default:
            break
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        isReachable = session.isReachable
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
