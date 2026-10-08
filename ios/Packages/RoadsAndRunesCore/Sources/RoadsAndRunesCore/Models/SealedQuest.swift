import Foundation

/// `POST /quests/sealed` (0.7.3): pick a time, the board picks the way.
public struct SealedQuestRequest: Codable, Hashable, Sendable {
    public var minutes: Int
    public var latitude: Double
    public var longitude: Double
    public var activity: Activity?

    public init(minutes: Int, latitude: Double, longitude: Double, activity: Activity? = nil) {
        self.minutes = minutes
        self.latitude = latitude
        self.longitude = longitude
        self.activity = activity
    }

    public init(minutes: Int, at origin: Coordinate, activity: Activity? = nil) {
        self.init(minutes: minutes, latitude: origin.latitude, longitude: origin.longitude, activity: activity)
    }
}

/// A sealed quest keeps its goal shut until the journey is far enough along its
/// route (docs/ROADMAP.md, 0.7.3). Pure rules, so the quest card, the ride
/// screen and Journey's end all agree.
public enum SealedQuest {
    /// Halfway, unless the quest says otherwise.
    public static let defaultRevealAtFraction = 0.5
    /// The lengths the board offers.
    public static let minuteChoices = [20, 40, 90]
    /// What the card says in place of the goal.
    public static let shutLine = "The goal opens halfway."

    /// How far along the route the goal opens, or nil for any other quest. Read
    /// from the quest's `extra`, then any objective's; a quest typed SEALED
    /// without a number opens halfway.
    public static func revealAtFraction(of quest: Quest) -> Double? {
        if let value = quest.extra?["revealAtFraction"]?.doubleValue { return clamp(value) }
        for objective in quest.objectives {
            if let value = objective.extra?["revealAtFraction"]?.doubleValue { return clamp(value) }
        }
        let kinds = [quest.questType, quest.templateId].map { $0.uppercased() }
        if kinds.contains(where: { $0 == "SEALED" || $0.hasPrefix("SEALED_") }) || quest.extra?["sealed"]?.boolValue == true {
            return defaultRevealAtFraction
        }
        return nil
    }

    public static func isSealed(_ quest: Quest?) -> Bool {
        guard let quest else { return false }
        return revealAtFraction(of: quest) != nil
    }

    /// Whether the goal may be named at all: any quest that is not sealed; a sealed
    /// one once the route is far enough along, once its goal is done, or once the
    /// quest is over.
    public static func isOpen(_ quest: Quest, routeFraction: Double?) -> Bool {
        guard let reveal = revealAtFraction(of: quest) else { return true }
        let required = quest.requiredObjectives
        if quest.status == .completed || (!required.isEmpty && required.allSatisfy(\.isCompleted)) { return true }
        guard let routeFraction else { return false }
        return routeFraction + 1e-9 >= reveal
    }

    /// On the ride screen the goal is read only at a standstill, like every other
    /// line there: open, and still.
    public static func showsGoalWhileRiding(_ quest: Quest, routeFraction: Double?, isStill: Bool) -> Bool {
        guard isSealed(quest) else { return true }
        return isStill && isOpen(quest, routeFraction: routeFraction)
    }

    /// What the goal is, sent in the quest's `extra.goal` by the server (the hidden
    /// objective itself says only "Reach the goal"): the phone keeps it back until it opens.
    public struct Goal: Hashable, Sendable {
        /// "Ride to Stave Hill", "Run to the Fen Troll".
        public var title: String
        public var name: String?
        /// PLACE, CREATURE or TILE.
        public var kind: String?
        /// A `GameIcon` name for its face.
        public var icon: String?
        public var coordinate: Coordinate?
    }

    /// The goal of a sealed quest, from the first objective that carries one, else
    /// the first required objective's own title. Nil for any other quest.
    public static func goal(of quest: Quest) -> Goal? {
        guard isSealed(quest) else { return nil }
        // The quest's own `extra.goal` first (the server's), then an objective's.
        let carriers: [(goal: [String: JSONValue], objective: Objective?)] =
            (quest.extra?["goal"]?.objectValue.map { [($0, quest.requiredObjectives.first)] } ?? [])
            + quest.sortedObjectives.compactMap { objective in objective.extra?["goal"]?.objectValue.map { ($0, objective) } }
        if let carrier = carriers.first {
            let goal = carrier.goal
            let name = goal["name"]?.stringValue
            let title = goal["title"]?.stringValue ?? name.map { "Reach \($0)" } ?? carrier.objective?.title ?? "Reach the goal"
            let coordinate = goal["latitude"]?.doubleValue.flatMap { lat in
                goal["longitude"]?.doubleValue.map { Coordinate(latitude: lat, longitude: $0) }
            }
            return Goal(title: title, name: name, kind: goal["kind"]?.stringValue, icon: goal["icon"]?.stringValue,
                        coordinate: coordinate ?? carrier.objective?.coordinate)
        }
        guard let objective = quest.requiredObjectives.first ?? quest.sortedObjectives.first else { return nil }
        let name = objective.extra?["poiName"]?.stringValue ?? objective.extra?["objectName"]?.stringValue
        return Goal(title: objective.title, name: name, kind: nil, icon: nil, coordinate: objective.coordinate)
    }

    /// "Sealed quest (40 min)": the minutes asked for, read back from the quest.
    public static func minutes(of quest: Quest) -> Int? {
        if let minutes = quest.extra?["minutes"]?.intValue { return minutes }
        return quest.estimatedDurationMinutes > 0 ? quest.estimatedDurationMinutes : nil
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
