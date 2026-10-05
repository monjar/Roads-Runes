import Foundation

// Between rides on the wrist (0.7.3): Next up on the Watch's idle screen and the
// complication. The phone sends `WatchIdleInfo` whenever its World refreshes, in
// the application context beside whatever ride message is there; the Watch keeps
// the last one in the app group, where its complication reads it. Like every
// Watch message it only grows: a field an older phone lacks decodes to nothing.

/// iPhone → Watch: what the idle screen offers between journeys.
public struct WatchIdleInfo: Codable, Hashable, Sendable {
    /// Today's bounty, as the Watch shows it.
    public struct Bounty: Codable, Hashable, Sendable {
        public var id: UUID?
        public var name: String
        /// Its mark as a `GameIcon` raw name; the Watch falls back to the species.
        public var icon: String?
        public var speciesId: String?
        /// From where the phone last knew the rider to be.
        public var distanceMeters: Double?
        public var expiresAt: Date?

        public init(id: UUID? = nil, name: String, icon: String? = nil, speciesId: String? = nil, distanceMeters: Double? = nil,
                    expiresAt: Date? = nil) {
            self.id = id
            self.name = name
            self.icon = icon
            self.speciesId = speciesId
            self.distanceMeters = distanceMeters
            self.expiresAt = expiresAt
        }
    }

    /// A quest the rider has taken and can start from the wrist.
    public struct StartableQuest: Codable, Hashable, Identifiable, Sendable {
        public var id: UUID
        public var title: String
        /// A `GameIcon` raw name.
        public var icon: String?
        /// To its next objective, from where the phone last knew the rider to be.
        public var distanceMeters: Double?

        public init(id: UUID, title: String, icon: String? = nil, distanceMeters: Double? = nil) {
            self.id = id
            self.title = title
            self.icon = icon
            self.distanceMeters = distanceMeters
        }
    }

    /// Today's pledge, when there is one.
    public struct Pledge: Codable, Hashable, Sendable {
        public var targetName: String
        public var icon: String?

        public init(targetName: String, icon: String? = nil) {
            self.targetName = targetName
            self.icon = icon
        }
    }

    /// At most this many quests go to the wrist.
    public static let questLimit = 3

    public var streakDays: Int
    public var streakActiveToday: Bool
    public var bounty: Bounty?
    public var quests: [StartableQuest]
    /// RIDE, RUN or WALK: the rider's usual, so the Watch says "Run to bounty" to a runner.
    public var activity: String?
    public var pledge: Pledge?
    /// METRIC or IMPERIAL, for the complication, which hears nothing else from the phone.
    public var units: String?
    /// When the phone made it: a streak not kept that day lapses the day after.
    public var updatedAt: Date?

    public init(streakDays: Int = 0, streakActiveToday: Bool = false, bounty: Bounty? = nil, quests: [StartableQuest] = [],
                activity: String? = nil, pledge: Pledge? = nil, units: String? = nil, updatedAt: Date? = Date()) {
        self.streakDays = max(0, streakDays)
        self.streakActiveToday = streakActiveToday
        self.bounty = bounty
        self.quests = Array(quests.prefix(Self.questLimit))
        self.activity = activity
        self.pledge = pledge
        self.units = units
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case streakDays, streakActiveToday, bounty, quests, activity, pledge, units, updatedAt
    }

    /// Lenient: what is missing is nothing, so any phone's shape is read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            streakDays: try container.decodeIfPresent(Int.self, forKey: .streakDays) ?? 0,
            streakActiveToday: try container.decodeIfPresent(Bool.self, forKey: .streakActiveToday) ?? false,
            bounty: try container.decodeIfPresent(Bounty.self, forKey: .bounty),
            quests: try container.decodeIfPresent([StartableQuest].self, forKey: .quests) ?? [],
            activity: try container.decodeIfPresent(String.self, forKey: .activity),
            pledge: try container.decodeIfPresent(Pledge.self, forKey: .pledge),
            units: try container.decodeIfPresent(String.self, forKey: .units),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        )
    }

    public var activityKind: Activity? {
        guard let activity else { return nil }
        let parsed = Activity.lenient(activity)
        return parsed.isUnknown ? nil : parsed
    }

    /// The bounty while it is still out at `date` (one with no end stays out).
    public func liveBounty(at date: Date = Date()) -> Bounty? {
        guard let bounty else { return nil }
        if let expiresAt = bounty.expiresAt, expiresAt <= date { return nil }
        return bounty
    }

    /// The streak as it stands at `date`: one not kept on the day it was sent still
    /// counts the next day, and has lapsed the day after.
    public func streak(at date: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let updatedAt else { return streakDays }
        let sent = calendar.startOfDay(for: updatedAt)
        let today = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: sent, to: today).day ?? 0
        if days <= 0 { return streakDays }
        if days == 1 && streakActiveToday { return streakDays }
        return 0
    }

    /// Whether the streak has been kept today, as it stands at `date`.
    public func streakKept(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard streakActiveToday else { return false }
        guard let updatedAt else { return true }
        return calendar.isDate(updatedAt, inSameDayAs: date)
    }

    /// The same thing to say, from the same day: sending it again would change nothing.
    public func says(sameAs other: WatchIdleInfo?, calendar: Calendar = .current) -> Bool {
        guard var other else { return false }
        var mine = self
        let sameDay: Bool
        switch (mine.updatedAt, other.updatedAt) {
        case let (a?, b?): sameDay = calendar.isDate(a, inSameDayAs: b)
        case (nil, nil): sameDay = true
        default: sameDay = false
        }
        mine.updatedAt = nil
        other.updatedAt = nil
        return sameDay && mine == other
    }
}

// MARK: - Made on the phone

public extension WatchIdleInfo {
    /// Next up from what the phone has loaded: the streak, the nearest live bounty,
    /// the quests the rider has taken (under way first, then accepted, at most
    /// three, none run out), the rider's usual activity and today's pledge.
    /// `icon` and `questIcon` name `GameIcon`s: the phone knows the art, Core does not.
    static func make(
        character: Character?, objects: [WorldObject], quests: [Quest], position: Coordinate?, activity: Activity,
        units: Units, pledge: Pledge? = nil, now: Date = Date(),
        icon: (WorldObject) -> String? = { _ in nil }, questIcon: (Quest) -> String? = { _ in nil }
    ) -> WatchIdleInfo {
        let bounties = objects.filter { $0.isBounty && $0.status == .spawned && $0.expiresAt > now }
        let nearest: WorldObject? = {
            guard let position else { return bounties.first }
            return bounties.min { GeoMath.distance(position, $0.coordinate) < GeoMath.distance(position, $1.coordinate) }
        }()
        let bounty = nearest.map { object in
            Bounty(id: object.id, name: object.name, icon: icon(object), speciesId: object.monster?.speciesId,
                   distanceMeters: position.map { GeoMath.distance($0, object.coordinate) }, expiresAt: object.expiresAt)
        }
        let rank: (QuestStatus) -> Int? = { status in
            switch status {
            case .active: return 0
            case .accepted: return 1
            default: return nil
            }
        }
        var seen: Set<UUID> = []
        let startable = quests
            .filter { rank($0.status) != nil && ($0.expiresAt.map { $0 > now } ?? true) && seen.insert($0.id).inserted }
            .enumerated()
            .sorted { (rank($0.element.status) ?? 9, $0.offset) < (rank($1.element.status) ?? 9, $1.offset) }
            .prefix(questLimit)
            .map { entry -> StartableQuest in
                let quest = entry.element
                let next = quest.sortedObjectives.first { !$0.isCompleted && $0.coordinate != nil }?.coordinate
                let meters: Double? = {
                    guard let position, let next else { return nil }
                    return GeoMath.distance(position, next)
                }()
                return StartableQuest(id: quest.id, title: quest.title, icon: questIcon(quest), distanceMeters: meters)
            }
        return WatchIdleInfo(
            streakDays: character?.streakDays ?? 0,
            streakActiveToday: character?.streakActiveToday ?? false,
            bounty: bounty,
            quests: Array(startable),
            activity: activity.isUnknown ? nil : activity.rawValue,
            pledge: pledge,
            units: units.isUnknown ? nil : units.rawValue,
            updatedAt: now
        )
    }
}

// MARK: - Kept on the Watch

/// The creature the journey under way was planned for, as the complication shows it.
public struct WatchQuarry: Codable, Hashable, Sendable {
    public var name: String
    public var icon: String?
    public var speciesId: String?

    public init(name: String, icon: String? = nil, speciesId: String? = nil) {
        self.name = name
        self.icon = icon
        self.speciesId = speciesId
    }

    public init(mark: WatchWorldMark) {
        self.init(name: mark.name, icon: mark.icon, speciesId: mark.speciesId)
    }
}

/// Where the Watch keeps Next up and the quarry for its complication: the app
/// group the Watch app and its widget extension share. Each write says whether it
/// changed anything, so the timelines are reloaded only when there is news.
public enum WatchIdleStore {
    public static let appGroup = "group.com.roadsandrunes.app"
    public static let idleKey = "watch.idle.v1"
    public static let quarryKey = "watch.quarry.v1"

    /// The app group's defaults, or nil where the group is not provisioned.
    public static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static func readIdle(from defaults: UserDefaults? = sharedDefaults) -> WatchIdleInfo? {
        read(WatchIdleInfo.self, key: idleKey, from: defaults)
    }

    public static func readQuarry(from defaults: UserDefaults? = sharedDefaults) -> WatchQuarry? {
        read(WatchQuarry.self, key: quarryKey, from: defaults)
    }

    /// Stores Next up (nil clears it); true when what is stored changed.
    @discardableResult
    public static func write(idle: WatchIdleInfo?, to defaults: UserDefaults? = sharedDefaults) -> Bool {
        write(idle, key: idleKey, to: defaults)
    }

    /// Stores the quarry (nil when no journey is under way); true when it changed.
    @discardableResult
    public static func write(quarry: WatchQuarry?, to defaults: UserDefaults? = sharedDefaults) -> Bool {
        write(quarry, key: quarryKey, to: defaults)
    }

    private static func read<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults?) -> T? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONCoding.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T?, key: String, to defaults: UserDefaults?) -> Bool {
        guard let defaults else { return false }
        guard let value else {
            guard defaults.data(forKey: key) != nil else { return false }
            defaults.removeObject(forKey: key)
            return true
        }
        guard let data = try? JSONCoding.encode(value) else { return false }
        if defaults.data(forKey: key) == data { return false }
        defaults.set(data, forKey: key)
        return true
    }
}

// MARK: - The complication

/// What the complication says, worked out from Next up and the quarry: the
/// quarry's mark while a journey is under way, else the bounty's, else the streak.
public struct WatchComplication: Hashable, Sendable {
    public enum Mark: Hashable, Sendable {
        case quarry(name: String, icon: String?, speciesId: String?)
        case bounty(name: String, icon: String?, speciesId: String?)

        public var name: String {
            switch self {
            case let .quarry(name, _, _), let .bounty(name, _, _): return name
            }
        }

        public var icon: String? {
            switch self {
            case let .quarry(_, icon, _), let .bounty(_, icon, _): return icon
            }
        }

        public var speciesId: String? {
            switch self {
            case let .quarry(_, _, species), let .bounty(_, _, species): return species
            }
        }

        public var isQuarry: Bool {
            if case .quarry = self { return true }
            return false
        }
    }

    public var mark: Mark?
    public var streakDays: Int
    public var streakKeptToday: Bool
    public var bountyName: String?
    public var bountyDistanceMeters: Double?
    public var units: Units

    public init(mark: Mark?, streakDays: Int, streakKeptToday: Bool, bountyName: String?, bountyDistanceMeters: Double?,
                units: Units = .metric) {
        self.mark = mark
        self.streakDays = streakDays
        self.streakKeptToday = streakKeptToday
        self.bountyName = bountyName
        self.bountyDistanceMeters = bountyDistanceMeters
        self.units = units
    }

    public init(idle: WatchIdleInfo?, quarry: WatchQuarry?, at date: Date = Date(), calendar: Calendar = .current) {
        let bounty = idle?.liveBounty(at: date)
        let mark: Mark? = {
            if let quarry { return .quarry(name: quarry.name, icon: quarry.icon, speciesId: quarry.speciesId) }
            if let bounty { return .bounty(name: bounty.name, icon: bounty.icon, speciesId: bounty.speciesId) }
            return nil
        }()
        let units = idle?.units.map(Units.lenient) ?? .metric
        self.init(
            mark: mark,
            streakDays: idle?.streak(at: date, calendar: calendar) ?? 0,
            streakKeptToday: idle?.streakKept(at: date, calendar: calendar) ?? false,
            bountyName: bounty?.name,
            bountyDistanceMeters: bounty?.distanceMeters,
            units: units.isUnknown ? .metric : units
        )
    }

    /// For the watch-face gallery: nothing here is real.
    public static let placeholder = WatchComplication(
        mark: .bounty(name: "Fen Troll", icon: "troll", speciesId: "fen-troll"), streakDays: 4, streakKeptToday: true,
        bountyName: "Fen Troll", bountyDistanceMeters: 2_400
    )

    /// "4-day streak", or "Start a streak" with none.
    public var streakLine: String {
        streakDays > 0 ? LoreCopy.streak(streakDays) : "Start a streak"
    }

    /// "2.4 km away", when the bounty's distance is known.
    public var bountyDistanceLine: String? {
        bountyDistanceMeters.map { "\(UnitFormatter(units: units).distance(meters: $0)) away" }
    }

    /// One line beside the time: "Streak 4 · Bounty: Fen Troll".
    public var inlineText: String {
        var parts: [String] = []
        if streakDays > 0 { parts.append("Streak \(streakDays)") }
        if let bountyName { parts.append("Bounty: \(bountyName)") }
        return parts.isEmpty ? "Roads & Runes" : parts.joined(separator: " · ")
    }

    /// The times the complication should be worked out again by itself: when the
    /// bounty runs out, and at midnight, when a streak not kept can lapse.
    public static func refreshDates(idle: WatchIdleInfo?, after date: Date, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        if let ends = idle?.liveBounty(at: date)?.expiresAt, ends > date { dates.append(ends) }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) { dates.append(midnight) }
        return Array(Set(dates)).sorted()
    }
}
