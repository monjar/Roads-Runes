import Foundation
import OSLog
import RoadsAndRunesCore

/// Structured client logging + product analytics (spec §78–79). Events go to
/// os.Logger; a remote sink can be added without touching call sites.
final class OSLogAnalytics: AnalyticsSink, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.roadsandrunes.app", category: "analytics")

    func track(_ event: AnalyticsEvent, properties: [String: String]) {
        let props = properties.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        logger.info("event=\(event.rawValue, privacy: .public) \(props, privacy: .public)")
    }
}

enum AppLog {
    static let navigation = Logger(subsystem: "com.roadsandrunes.app", category: "navigation")
    static let ride = Logger(subsystem: "com.roadsandrunes.app", category: "ride")
    static let sync = Logger(subsystem: "com.roadsandrunes.app", category: "sync")
    static let watch = Logger(subsystem: "com.roadsandrunes.app", category: "watch")
    static let api = Logger(subsystem: "com.roadsandrunes.app", category: "api")
}
