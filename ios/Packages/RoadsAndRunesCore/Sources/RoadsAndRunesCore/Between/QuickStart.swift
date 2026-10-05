import Foundation

/// What a quick start asks for (0.7.3): from Siri and the Shortcuts app, the
/// Action Button, a widget's deep link or the Watch. The app's
/// `QuickStartCoordinator` turns one into a planned route with Start ready.
public enum QuickStart: Codable, Hashable, Sendable {
    /// A loop from here that lasts about `minutes` at the activity's usual pace.
    case loop(minutes: Int, activity: Activity)
    /// A route to today's bounty.
    case bounty
    /// The board picks the way and keeps the goal shut until halfway.
    case sealed(minutes: Int)
    /// A quest already on the board.
    case quest(id: UUID)

    /// The lengths a sealed quest comes in, as the server accepts them.
    public static let sealedMinuteChoices = [20, 40, 90]

    /// The quick loops offered on the Watch and in Shortcuts.
    public static let loopMinuteChoices = [20, 40, 60]

    /// The sealed length nearest to what was asked ("something for 45 minutes" is 40).
    public static func sealedMinutes(nearest minutes: Int) -> Int {
        sealedMinuteChoices.min { abs($0 - minutes) < abs($1 - minutes) } ?? 40
    }

    /// The minutes this start asks for, when it asks for any.
    public var minutes: Int? {
        switch self {
        case .loop(let minutes, _), .sealed(let minutes): return minutes
        case .bounty, .quest: return nil
        }
    }
}

// MARK: - Minutes into distance

extension Activity {
    /// The pace a plan assumes for this activity, matching the server's
    /// `ASSUMED_SPEED_KMH` in `backend/app/core/activity.py`.
    public var usualSpeedKmh: Double {
        switch self {
        case .run: return 9.5
        case .walk: return 4.8
        default: return 15.0
        }
    }

    /// How far this activity goes in `minutes` at its usual pace.
    public func distanceMeters(forMinutes minutes: Int) -> Double {
        usualSpeedKmh * 1000 * Double(max(0, minutes)) / 60
    }
}

extension QuickStart {
    /// The loop distance a quick loop asks the planner for, in kilometres
    /// (`POST /routes/generate`'s `distanceTargetKm`), never under one kilometre.
    public static func loopDistanceKm(minutes: Int, activity: Activity) -> Double {
        let km = activity.distanceMeters(forMinutes: minutes) / 1000
        return max(1, (km * 10).rounded() / 10)
    }

    /// `loopDistanceKm` for a `.loop`; nil for every other start.
    public var loopDistanceKm: Double? {
        guard case .loop(let minutes, let activity) = self else { return nil }
        return Self.loopDistanceKm(minutes: minutes, activity: activity)
    }
}

// MARK: - Deep links

/// Where a `roadsandrunes://` link opens the app: from a widget, a Live Activity
/// or a Shortcut.
///
/// - `roadsandrunes://world`
/// - `roadsandrunes://bounty`
/// - `roadsandrunes://quests`
/// - `roadsandrunes://quickstart?minutes=40` (a sealed quest of that length)
/// - `roadsandrunes://quickstart?kind=loop&minutes=40&activity=RUN`
/// - `roadsandrunes://quickstart?kind=bounty`
/// - `roadsandrunes://quickstart?kind=quest&id=<uuid>`
/// - `roadsandrunes://ride` (back to the ride on screen, from the Live Activity)
public enum DeepLink: Hashable, Sendable {
    case world
    case bounty
    case quests
    case ride
    case quickStart(QuickStart)

    public static let scheme = "roadsandrunes"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // `roadsandrunes://world` puts "world" in the host; tolerate `roadsandrunes:///world` too.
        let head = (url.host ?? url.pathComponents.first { $0 != "/" } ?? "").lowercased()
        switch head {
        case "world": self = .world
        case "bounty": self = .bounty
        case "quests": self = .quests
        case "ride": self = .ride
        case "quickstart":
            guard let start = Self.quickStart(from: url) else { return nil }
            self = .quickStart(start)
        default: return nil
        }
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .world: parts.host = "world"
        case .bounty: parts.host = "bounty"
        case .quests: parts.host = "quests"
        case .ride: parts.host = "ride"
        case .quickStart(let start):
            parts.host = "quickstart"
            parts.queryItems = Self.queryItems(for: start)
        }
        // Every piece above is ASCII and well formed, so this cannot fail.
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    private static func quickStart(from url: URL) -> QuickStart? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let minutes = value("minutes").flatMap(Int.init)
        switch value("kind")?.lowercased() ?? "sealed" {
        case "sealed":
            return .sealed(minutes: QuickStart.sealedMinutes(nearest: minutes ?? 40))
        case "loop":
            let activity = value("activity").map(Activity.lenient) ?? .ride
            return .loop(minutes: max(5, minutes ?? 40), activity: activity.isUnknown ? .ride : activity)
        case "bounty":
            return .bounty
        case "quest":
            guard let id = value("id").flatMap(UUID.init(uuidString:)) else { return nil }
            return .quest(id: id)
        default:
            return nil
        }
    }

    private static func queryItems(for start: QuickStart) -> [URLQueryItem] {
        switch start {
        case .sealed(let minutes):
            return [URLQueryItem(name: "minutes", value: String(minutes))]
        case .loop(let minutes, let activity):
            return [
                URLQueryItem(name: "kind", value: "loop"),
                URLQueryItem(name: "minutes", value: String(minutes)),
                URLQueryItem(name: "activity", value: activity.rawValue),
            ]
        case .bounty:
            return [URLQueryItem(name: "kind", value: "bounty")]
        case .quest(let id):
            return [URLQueryItem(name: "kind", value: "quest"), URLQueryItem(name: "id", value: id.uuidString)]
        }
    }
}
