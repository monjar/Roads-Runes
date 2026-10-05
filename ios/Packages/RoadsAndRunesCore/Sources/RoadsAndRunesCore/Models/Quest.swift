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
    /// Who put the notice up, and one of their lines (0.6.2). Optional: an older
    /// server sends none.
    public var poster: QuestPoster?

    public init(hook: String? = nil, completion: String? = nil, poster: QuestPoster? = nil) {
        self.hook = hook
        self.completion = completion
        self.poster = poster
    }
}

/// A cast member and one of their lines, on a notice (docs/WORLD.md).
public struct QuestPoster: Codable, Hashable, Sendable {
    public var castId: String
    public var name: String
    public var line: String

    public init(castId: String, name: String, line: String) {
        self.castId = castId
        self.name = name
        self.line = line
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
    /// What the levels gained gave (0.7.2): "Lantern slot opens", "2 lamps".
    public var rewards: [LevelReward]?

    public init(kind: LevelKind, from: Int, to: Int, rewards: [LevelReward]? = nil) {
        self.kind = kind
        self.from = from
        self.to = to
        self.rewards = rewards
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

/// Where finishing a story step leaves the rider in its arc.
public struct StoryStanding: Codable, Hashable, Sendable {
    public struct Reward: Codable, Hashable, Sendable {
        public var title: String?
        public var ac: Int?
        /// A chapter of Act II teaches its rune (0.7.0).
        public var rune: String?

        public init(title: String? = nil, ac: Int? = nil, rune: String? = nil) {
            self.title = title
            self.ac = ac
            self.rune = rune
        }
    }

    public var arcSlug: String?
    public var arcTitle: String
    public var stepTitle: String?
    public var stepsDone: Int
    public var stepsTotal: Int
    public var arcCompleted: Bool
    public var nextTitle: String?
    public var reward: Reward?

    public init(arcSlug: String? = nil, arcTitle: String, stepTitle: String? = nil, stepsDone: Int, stepsTotal: Int, arcCompleted: Bool, nextTitle: String? = nil, reward: Reward? = nil) {
        self.arcSlug = arcSlug
        self.arcTitle = arcTitle
        self.stepTitle = stepTitle
        self.stepsDone = stepsDone
        self.stepsTotal = stepsTotal
        self.arcCompleted = arcCompleted
        self.nextTitle = nextTitle
        self.reward = reward
    }
}

public struct QuestCompletion: Codable, Hashable, Sendable {
    public var quest: Quest
    public var xpAwarded: Int
    public var xpBreakdown: [XPBreakdownEntry]
    public var levelUps: [LevelUp]
    public var abilitiesUnlocked: [Ability]
    public var titlesUnlocked: [String]
    public var storyProgress: StoryStanding?

    public init(quest: Quest, xpAwarded: Int, xpBreakdown: [XPBreakdownEntry], levelUps: [LevelUp], abilitiesUnlocked: [Ability], titlesUnlocked: [String], storyProgress: StoryStanding? = nil) {
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
    /// A note written for it (a WRITE_NOTE, or Ansuz's INSCRIBE_RUNE), for the server to judge.
    public var note: String?

    public init(objectiveId: UUID, occurredAt: Date, latitude: Double? = nil, longitude: Double? = nil, value: Double? = nil, note: String? = nil) {
        self.objectiveId = objectiveId
        self.occurredAt = occurredAt
        self.latitude = latitude
        self.longitude = longitude
        self.value = value
        self.note = note
    }

    public init(objectiveId: UUID, occurredAt: Date, coordinate: Coordinate?, value: Double? = nil, note: String? = nil) {
        self.init(objectiveId: objectiveId, occurredAt: occurredAt, latitude: coordinate?.latitude, longitude: coordinate?.longitude, value: value, note: note)
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
    /// COMPLETED (done) · OPEN (on the board now) · READY (next up) · WAITING (next
    /// up, but it cannot be set where the player is) · LOCKED
    public enum State: String, SafeEnum {
        case completed = "COMPLETED"
        case open = "OPEN"
        case ready = "READY"
        case waiting = "WAITING"
        case locked = "LOCKED"
        case unknown = "UNKNOWN"
    }

    public var slug: String
    public var sequence: Int
    public var title: String
    public var description: String
    public var state: State
    /// Why a WAITING step cannot be set here ("Waiting for high ground within reach.").
    public var waitingReason: String?
    /// The quest on the board for this step, while there is one.
    public var questId: UUID?

    public var id: String { slug }

    public init(slug: String, sequence: Int, title: String, description: String, state: State, waitingReason: String? = nil, questId: UUID? = nil) {
        self.slug = slug
        self.sequence = sequence
        self.title = title
        self.description = description
        self.state = state
        self.waitingReason = waitingReason
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
    /// The campaign (0.6.2): MAIN or SIDE, its act and chapter, the chapter it comes
    /// after, the cast id of who posts it, and what finishing it gives. All optional.
    public var track: String?
    public var act: Int?
    public var actTitle: String?
    public var chapter: Int?
    public var after: String?
    public var giver: String?
    public var reward: StoryStanding.Reward?

    public var id: String { slug }

    public var completedCount: Int { quests.filter { $0.state == .completed }.count }
    public var isComplete: Bool { !quests.isEmpty && completedCount == quests.count }
    /// The campaign, as opposed to a trade's own arc.
    public var isCampaign: Bool { track == "MAIN" }

    public init(slug: String, title: String, description: String, characterClass: CharacterClass? = nil, minLevel: Int, unlocked: Bool, quests: [StoryStep],
                track: String? = nil, act: Int? = nil, actTitle: String? = nil, chapter: Int? = nil, after: String? = nil, giver: String? = nil,
                reward: StoryStanding.Reward? = nil) {
        self.slug = slug
        self.title = title
        self.description = description
        self.characterClass = characterClass
        self.minLevel = minLevel
        self.unlocked = unlocked
        self.quests = quests
        self.track = track
        self.act = act
        self.actTitle = actTitle
        self.chapter = chapter
        self.after = after
        self.giver = giver
        self.reward = reward
    }
}


/// The week's notice (`GET /quests/week`, 0.6.2): one goal an ISO week, a fixed
/// target, paid once.
public struct WeekNotice: Codable, Hashable, Sendable {
    public var week: String
    /// OUTINGS, NEW_GROUND, PLACES or SEEN_OFF.
    public var kind: String
    public var title: String
    public var line: String?
    public var postedBy: String?
    public var target: Int
    public var unit: String
    public var progress: Int
    public var done: Bool
    public var paid: Bool
    public var coins: Int?
    public var xp: Int?
    public var endsAt: Date?

    public var fraction: Double { target > 0 ? min(1, Double(progress) / Double(target)) : 0 }

    public init(week: String, kind: String, title: String, line: String? = nil, postedBy: String? = nil, target: Int, unit: String,
                progress: Int, done: Bool, paid: Bool, coins: Int? = nil, xp: Int? = nil, endsAt: Date? = nil) {
        self.week = week
        self.kind = kind
        self.title = title
        self.line = line
        self.postedBy = postedBy
        self.target = target
        self.unit = unit
        self.progress = progress
        self.done = done
        self.paid = paid
        self.coins = coins
        self.xp = xp
        self.endsAt = endsAt
    }
}
