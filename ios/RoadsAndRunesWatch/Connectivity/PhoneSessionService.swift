import Foundation
import OSLog
import RoadsAndRunesCore
import WatchConnectivity

/// Receives route summaries, navigation updates and objective events from
/// the iPhone; sends commands and heart-rate samples back. Keeps the last
/// instruction when the phone drops and never invents navigation.
final class PhoneSessionService: NSObject, WCSessionDelegate {
    private let store: RideStore
    private let logger = Logger(subsystem: "com.roadsandrunes.app.watchkitapp", category: "connectivity")
    private var lastHeartRateSent: Date = .distantPast

    init(store: RideStore) {
        self.store = store
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

    private func deliver(_ message: [String: Any], urgent: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { [logger] error in
                logger.warning("send_failed error=\(error.localizedDescription, privacy: .public)")
                if urgent { session.transferUserInfo(message) }
            }
        } else if urgent {
            session.transferUserInfo(message)
        }
    }

    // MARK: - Inbound

    private func handle(_ message: [String: Any]) {
        guard let kind = WatchMessages.kind(of: message) else { return }
        let receivedAt = Date()
        do {
            switch kind {
            case .routeSummary:
                let summary = try WatchMessages.routeSummary(from: message)
                Task { @MainActor in self.store.apply(summary: summary, receivedAt: receivedAt) }
            case .navigationUpdate:
                let update = try WatchMessages.navigationUpdate(from: message)
                Task { @MainActor in self.store.apply(update: update, receivedAt: receivedAt) }
            case .objectiveCompleted:
                let event = try WatchMessages.objectiveCompleted(from: message)
                Task { @MainActor in self.store.apply(objective: event, receivedAt: receivedAt) }
            case .command, .heartRate:
                break
            }
        } catch {
            logger.error("decode_failed kind=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
        if let units = message["units"] as? String {
            Task { @MainActor in self.store.setUnits(raw: units) }
        }
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
