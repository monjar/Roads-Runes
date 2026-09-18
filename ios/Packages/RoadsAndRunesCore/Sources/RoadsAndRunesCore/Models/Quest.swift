import Foundation

public struct ObjectiveProgress: Codable, Hashable, Sendable {
    public var current: Double
    public var target: Double

    public init(current: Double, target: Double) {
        self.current = current
        self.target = target
    }

    public var fraction: Double {
        guard target > 0 else { return current > 0 ? 1 : 0 }
        return min(1, max(0, current / target))
    }
}

public struct Objective: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var objectiveType: ObjectiveType
    public var title: String
    public var latitude: Double?
    public var longitude: Double?
    public var radiusMeters: Double?
    public var targetMeters: Double?
    public var targetCells: [String]?
    public var targetElevationMeters: Double?
    public var targetCount: Int?
    public var discoveryId: UUID?
    public var required: Bool
    public var order: Int
    public var completionRule: CompletionRule
    public var status: ObjectiveStatus
    public var completedAt: Date?
    public var provisional: Bool?
    public var progress: ObjectiveProgress
    /// Template-specific payload, e.g. `cells` for VISIT_MULTIPLE_LOCATIONS.
    public var extra: [String: JSONValue]?

    public init(
        id: UUID, objectiveType: ObjectiveType, title: String, latitude: Double? = nil, longitude: Double? = nil,
        radiusMeters: Double? = nil, targetMeters: Double? = nil, targetCells: [String]? = nil,
        targetElevationMeters: Double? = nil, targetCount: Int? = nil, discoveryId: UUID? = nil,
        required: Bool, order: Int, completionRule: CompletionRule = .individual, status: ObjectiveStatus = .pending,
        completedAt: Date? = nil, provisional: Bool? = nil, progress: ObjectiveProgress, extra: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.objectiveType = objectiveType
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.targetMeters = targetMeters
        self.targetCells = targetCells
        self.targetElevationMeters = targetElevationMeters
        self.targetCount = targetCount
        self.discoveryId = discoveryId
        self.required = required
        self.order = order
        self.completionRule = completionRule
        self.status = status
        self.completedAt = completedAt
        self.provisional = provisional
        self.progress = progress
        self.extra = extra
    }

    public var coordinate: Coordinate? {
        guard let latitude = latitude, let longitude = longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    public var isCompleted: Bool { status == .completed }
}

public struct QuestNarrative: Codable, Hashable, Sendable {
    public var hook: String?
    public var completion: String?

    public init(hook: String? = nil, completion: String? = nil) {
        self.hook = hook
        self.completion = completion
    }
}

public struct QuestRewards: Codable, Hashable, Sendable {
    public var xp: Int?
    /// Active Coins on completion; nil from a server that predates them.
    public var ac: Int?
    public var items: [JSONValue]?
    public var titles: [String]?

    public init(xp: Int? = nil, ac: Int? = nil, items: [JSONValue]? = nil, titles: [String]? = nil) {
        self.xp = xp
        self.ac = ac
        self.items = items
        self.titles = titles
    }
}

public struct Quest: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var questType: String
    public var characterClass: CharacterClass
    public var templateId: String
    public var title: String
    public var description: String
    public var narrative: QuestNarrative
    public var difficulty: Difficulty
    public var recommendedDistanceKm: Double
    public var estimatedDurationMinutes: Int
    public var baseXP: Int
    public var status: QuestStatus
    public var expiresAt: Date?
    public var storyQuestId: UUID?
    public var partyId: UUID?
    public var origin: Coordinate
    public var objectives: [Objective]
    public var rewards: QuestRewards
    public var suggestedRouteId: UUID?
    public var rideId: UUID?
    public var acceptedAt: Date?
    public var startedAt: Date?
    public var completedAt: Date?
    public var createdAt: Date?
    /// How the quest is meant to be done; nil from a server that predates activities.
    public var activity: Activity?

    public init(
        id: UUID, questType: String, characterClass: CharacterClass, templateId: String, title: String, description: String,
        narrative: QuestNarrative = QuestNarrative(), difficulty: Difficulty, recommendedDistanceKm: Double,
        estimatedDurationMinutes: Int, baseXP: Int, status: QuestStatus, expiresAt: Date? = nil, storyQuestId: UUID? = nil,
        partyId: UUID? = nil, origin: Coordinate, objectives: [Objective], rewards: QuestRewards = QuestRewards(),
        suggestedRouteId: UUID? = nil, rideId: UUID? = nil, acceptedAt: Date? = nil, startedAt: Date? = nil,
        completedAt: Date? = nil, createdAt: Date? = nil, activity: Activity? = nil
    ) {
        self.activity = activity
        self.id = id
        self.questType = questType
        self.characterClass = characterClass
        self.templateId = templateId
        self.title = title
        self.description = description
        self.narrative = narrative
        self.difficulty = difficulty
        self.recommendedDistanceKm = recommendedDistanceKm
        self.estimatedDurationMinutes = estimatedDurationMinutes
        self.baseXP = baseXP
        self.status = status
        self.expiresAt = expiresAt
        self.storyQuestId = storyQuestId
        self.partyId = partyId
        self.origin = origin
        self.objectives = objectives
        self.rewards = rewards
        self.suggestedRouteId = suggestedRouteId
        self.rideId = rideId
        self.acceptedAt = acceptedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

    public var sortedObjectives: [Objective] { objectives.sorted { $0.order < $1.order } }
    public var requiredObjectives: [Objective] { sortedObjectives.filter { $0.required } }
}

public struct LevelUp: Codable, Hashable, Sendable {
    public var kind: LevelKind
    public var from: Int
    public var to: Int

    public init(kind: LevelKind, from: Int, to: Int) {
        self.kind = kind
        self.from = from
        self.to = to
    }
}

public struct XPBreakdownEntry: Codable, Hashable, Sendable {
    public var source: String
    public var xp: Int
    public var detail: JSONValue?

    public init(source: String, xp: Int, detail: JSONValue? = nil) {
        self.source = source
        self.xp = xp
        self.detail = detail
    }
}

public struct QuestCompletion: Codable, Hashable, Sendable {
    public var quest: Quest
    public var xpAwarded: Int
    public var xpBreakdown: [XPBreakdownEntry]
    public var levelUps: [LevelUp]
    public var abilitiesUnlocked: [Ability]
    public var titlesUnlocked: [String]
    public var storyProgress: JSONValue?

    public init(quest: Quest, xpAwarded: Int, xpBreakdown: [XPBreakdownEntry], levelUps: [LevelUp], abilitiesUnlocked: [Ability], titlesUnlocked: [String], storyProgress: JSONValue? = nil) {
        self.quest = quest
        self.xpAwarded = xpAwarded
        self.xpBreakdown = xpBreakdown
        self.levelUps = levelUps
        self.abilitiesUnlocked = abilitiesUnlocked
        self.titlesUnlocked = titlesUnlocked
        self.storyProgress = storyProgress
    }
}

// MARK: - Requests

public struct QuestGenerateRequest: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var count: Int
    public var request: String?
    /// nil: however this player usually moves.
    public var activity: Activity?

    public init(latitude: Double, longitude: Double, count: Int = 3, request: String? = nil, activity: Activity? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.count = count
        self.request = request
        self.activity = activity
    }
}

public struct QuestStartRequest: Codable, Hashable, Sendable {
    public var rideId: UUID?

    public init(rideId: UUID? = nil) {
        self.rideId = rideId
    }
}

public struct QuestCompleteRequest: Codable, Hashable, Sendable {
    public var rideId: UUID?

    public init(rideId: UUID? = nil) {
        self.rideId = rideId
    }
}

/// A client-observed objective event (quest progress and ride completion).
public struct ObjectiveEvent: Codable, Hashable, Sendable {
    public var objectiveId: UUID
    public var occurredAt: Date
    public var latitude: Double?
    public var longitude: Double?
    public var value: Double?

    public init(objectiveId: UUID, occurredAt: Date, latitude: Double? = nil, longitude: Double? = nil, value: Double? = nil) {
        self.objectiveId = objectiveId
        self.occurredAt = occurredAt
        self.latitude = latitude
        self.longitude = longitude
        self.value = value
    }

    public init(objectiveId: UUID, occurredAt: Date, coordinate: Coordinate?, value: Double? = nil) {
        self.init(objectiveId: objectiveId, occurredAt: occurredAt, latitude: coordinate?.latitude, longitude: coordinate?.longitude, value: value)
    }
}

public struct QuestProgressRequest: Codable, Hashable, Sendable {
    public var events: [ObjectiveEvent]

    public init(events: [ObjectiveEvent]) {
        self.events = events
    }
}

/// One step of an authored arc (`GET /quests/story`). The words are written; where
/// it sends the rider is generated from where they are, like any other quest.
public struct StoryStep: Codable, Hashable, Identifiable, Sendable {
    /// COMPLETED (ridden) · OPEN (on the board now) · READY (next up) · LOCKED
    public enum State: String, SafeEnum {
        case completed = "COMPLETED"
        case open = "OPEN"
        case ready = "READY"
        case locked = "LOCKED"
        case unknown = "UNKNOWN"
    }

    public var slug: String
    public var sequence: Int
    public var title: String
    public var description: String
    public var state: State
    /// The quest on the board for this step, while there is one.
    public var questId: UUID?

    public var id: String { slug }

    public init(slug: String, sequence: Int, title: String, description: String, state: State, questId: UUID? = nil) {
        self.slug = slug
        self.sequence = sequence
        self.title = title
        self.description = description
        self.state = state
        self.questId = questId
    }
}

/// An authored chain: a fixed order of steps where riding one opens the next.
public struct StoryArc: Codable, Hashable, Identifiable, Sendable {
    public var slug: String
    public var title: String
    public var description: String
    /// nil when the arc is for anyone.
    public var characterClass: CharacterClass?
    public var minLevel: Int
    /// Whether this rider's class and level have reached it. Locked arcs are still
    /// sent: what is coming is the reason to come back.
    public var unlocked: Bool
    public var quests: [StoryStep]

    public var id: String { slug }

    public var completedCount: Int { quests.filter { $0.state == .completed }.count }
    public var isComplete: Bool { !quests.isEmpty && completedCount == quests.count }

    public init(slug: String, title: String, description: String, characterClass: CharacterClass? = nil, minLevel: Int, unlocked: Bool, quests: [StoryStep]) {
        self.slug = slug
        self.title = title
        self.description = description
        self.characterClass = characterClass
        self.minLevel = minLevel
        self.unlocked = unlocked
        self.quests = quests
    }
}
