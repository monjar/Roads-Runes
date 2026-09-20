import Foundation

/// Build-time configuration read from Info.plist (fed by project.yml).
/// Single place for URLs, map styles and client-side feature defaults.
enum Config {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static var apiBaseURL: URL {
        let raw = (info["API_BASE_URL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: raw.isEmpty ? "http://localhost:8000" : raw) ?? URL(string: "http://localhost:8000")!
    }

    /// Sign in with Apple needs the `com.apple.developer.applesignin` entitlement,
    /// which a free Personal Team cannot sign; those builds pass APPLE_SIGN_IN_ENABLED=NO
    /// so the button is not offered at all rather than failing when tapped.
    static var allowsAppleSignIn: Bool {
        (info["APPLE_SIGN_IN_ENABLED"] as? String)?.uppercased() != "NO"
    }

    /// Developer sign-in is offered by development builds — a free Personal Team
    /// cannot sign "Sign in with Apple", and the hosted dev backend is HTTPS — and
    /// against any local backend. A Release build against HTTPS offers Apple only.
    static var allowsDevSignIn: Bool {
        #if DEBUG
        return true
        #else
        return apiBaseURL.scheme?.lowercased() == "http"
        #endif
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

        /// What the view draws on top of its base map. Cycling and Adventure used to be
        /// two hosted styles that looked alike; now each says what it is for.
        var emphasis: MapEmphasis {
            switch self {
            case .cycling: return .cycling
            case .adventure: return .adventure
            default: return .none
            }
        }
    }

    static let appGroup = "group.com.roadsandrunes.app"
    static let keychainService = "com.roadsandrunes.app.auth"
    static let ridePersistInterval: TimeInterval = 15
    static let pointsUploadBatchSize = 60
    static let explorationFlushCells = 50
    static let explorationFlushInterval: TimeInterval = 60
}
