import Foundation

/// What the home-screen and lock-screen widgets show (0.7.3), written by the
/// app into the shared app group and read by the widget extension, which never
/// touches the network.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public struct Bounty: Codable, Hashable, Sendable {
        public var name: String
        /// The creature's mark as a `GameIcon` raw name ("troll").
        public var icon: String?
        /// From where the app last knew the player to be.
        public var distanceMeters: Double?
        public var expiresAt: Date?

        public init(name: String, icon: String? = nil, distanceMeters: Double? = nil, expiresAt: Date? = nil) {
            self.name = name
            self.icon = icon
            self.distanceMeters = distanceMeters
            self.expiresAt = expiresAt
        }
    }

    public struct WeekNotice: Codable, Hashable, Sendable {
        public var title: String
        /// 0…1.
        public var progress: Double
        public var done: Bool

        public init(title: String, progress: Double, done: Bool) {
            self.title = title
            self.progress = min(1, max(0, progress))
            self.done = done
        }
    }

    public struct Pledge: Codable, Hashable, Sendable {
        public var targetName: String
        public var icon: String?

        public init(targetName: String, icon: String? = nil) {
            self.targetName = targetName
            self.icon = icon
        }
    }

    public var updatedAt: Date
    public var streakDays: Int
    public var streakActiveToday: Bool
    public var bounty: Bounty?
    public var weekNotice: WeekNotice?
    public var codexMet: Int?
    public var codexTotal: Int?
    public var level: Int?
    public var className: String?
    public var pledge: Pledge?
    /// How the player reads distances; nil from a snapshot that did not say (metric).
    public var units: Units?

    public init(
        updatedAt: Date = Date(), streakDays: Int = 0, streakActiveToday: Bool = false,
        bounty: Bounty? = nil, weekNotice: WeekNotice? = nil, codexMet: Int? = nil, codexTotal: Int? = nil,
        level: Int? = nil, className: String? = nil, pledge: Pledge? = nil, units: Units? = nil
    ) {
        self.updatedAt = updatedAt
        self.streakDays = streakDays
        self.streakActiveToday = streakActiveToday
        self.bounty = bounty
        self.weekNotice = weekNotice
        self.codexMet = codexMet
        self.codexTotal = codexTotal
        self.level = level
        self.className = className
        self.pledge = pledge
        self.units = units
    }

    /// Whether the bounty is still out at `date` (one without an expiry stays out).
    public func bountyIsLive(at date: Date = Date()) -> Bool {
        guard let bounty else { return false }
        guard let expiresAt = bounty.expiresAt else { return true }
        return expiresAt > date
    }

    /// The bounty, if it has not run out by `date`.
    public func liveBounty(at date: Date = Date()) -> Bounty? {
        bountyIsLive(at: date) ? bounty : nil
    }

    /// The streak as it stands at `date`: a streak not kept today still counts
    /// until the day after the snapshot ends, and then it has lapsed.
    public func streak(at date: Date = Date(), calendar: Calendar = .current) -> Int {
        let dayOfSnapshot = calendar.startOfDay(for: updatedAt)
        let today = calendar.startOfDay(for: date)
        let daysSince = calendar.dateComponents([.day], from: dayOfSnapshot, to: today).day ?? 0
        if daysSince <= 0 { return streakDays }
        // Kept the day of the snapshot: still alive tomorrow, gone the day after.
        if daysSince == 1 && streakActiveToday { return streakDays }
        return 0
    }

    /// A sample for widget previews and the gallery: nothing here is real.
    public static let placeholder = WidgetSnapshot(
        streakDays: 4, streakActiveToday: true,
        bounty: Bounty(name: "Fen Troll", icon: "troll", distanceMeters: 2_400),
        weekNotice: WeekNotice(title: "The week's quest", progress: 0.6, done: false),
        codexMet: 7, codexTotal: 24, level: 6, className: "Explorer"
    )

    /// "2.4 km" in the player's units.
    public func distance(_ meters: Double) -> String {
        UnitFormatter(units: units ?? .metric).distance(meters: meters)
    }
}

// MARK: - The app group

extension WidgetSnapshot {
    /// The app group the phone app, its widgets and the Watch share.
    public static let appGroup = "group.com.roadsandrunes.app"
    public static let defaultsKey = "widget.snapshot.v1"

    /// The app group's defaults, or nil where the group is not provisioned
    /// (a unit test host, a Personal Team build).
    public static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// The last snapshot written, or nil when there is none or it cannot be read.
    public static func read(from defaults: UserDefaults? = sharedDefaults) -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Stores this snapshot; returns false when there is nowhere to write it.
    @discardableResult
    public func write(to defaults: UserDefaults? = sharedDefaults) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }

    /// Removes the stored snapshot (signing out).
    public static func clear(in defaults: UserDefaults? = sharedDefaults) {
        defaults?.removeObject(forKey: defaultsKey)
    }
}
