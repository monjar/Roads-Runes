import Foundation

/// Build-time configuration read from Info.plist (fed by project.yml).
/// Single place for URLs, map styles and client-side feature defaults.
enum Config {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static var apiBaseURL: URL {
        let raw = (info["API_BASE_URL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: raw.isEmpty ? "http://localhost:8000" : raw) ?? URL(string: "http://localhost:8000")!
    }

    /// Developer sign-in is only offered against non-HTTPS (local) backends.
    static var allowsDevSignIn: Bool {
        apiBaseURL.scheme?.lowercased() == "http"
    }

    static func mapStyleURL(for style: MapStyleKey) -> URL {
        let key = "MAP_STYLE_\(style.rawValue)"
        let raw = info[key] as? String ?? "https://tiles.openfreemap.org/styles/bright"
        return URL(string: raw) ?? URL(string: "https://tiles.openfreemap.org/styles/bright")!
    }

    enum MapStyleKey: String {
        case minimal = "MINIMAL"
        case cycling = "CYCLING"
        case adventure = "ADVENTURE"
        case detailed = "DETAILED"
    }

    static let appGroup = "group.com.roadsandrunes.app"
    static let keychainService = "com.roadsandrunes.app.auth"
    static let ridePersistInterval: TimeInterval = 15
    static let pointsUploadBatchSize = 60
    static let explorationFlushCells = 50
    static let explorationFlushInterval: TimeInterval = 60
}
