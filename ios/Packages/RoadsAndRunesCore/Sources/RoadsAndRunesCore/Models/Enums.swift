import Foundation

public enum CharacterClass: String, SafeEnum {
    case explorer = "EXPLORER"
    case wizard = "WIZARD"
    case warrior = "WARRIOR"
    case scribe = "SCRIBE"
    /// A quest for anyone: not a class a character can be, but a class a quest can have.
    case any = "ANY"
    case unknown = "UNKNOWN"
}

/// How the player moves. The code keeps its cycling names (`Ride`, `RideRecorder`);
/// this is what changes the numbers, the workout and the words on screen.
public enum Activity: String, SafeEnum {
    case ride = "RIDE"
    case run = "RUN"
    case walk = "WALK"
    case unknown = "UNKNOWN"

    public var verb: String {
        switch self {
        case .run: return "Run"
        case .walk: return "Walk"
        default: return "Ride"
        }
    }

    public var noun: String { verb.lowercased() }

    public var symbol: String {
        switch self {
        case .run: return "figure.run"
        case .walk: return "figure.walk"
        default: return "bicycle"
        }
    }
}

public enum QuestStatus: String, SafeEnum {
    case available = "AVAILABLE"
    case accepted = "ACCEPTED"
    case active = "ACTIVE"
    case completed = "COMPLETED"
    case abandoned = "ABANDONED"
    case failed = "FAILED"
    case expired = "EXPIRED"
    case unknown = "UNKNOWN"
}

public enum ObjectiveType: String, SafeEnum {
    case visitLocation = "VISIT_LOCATION"
    case visitRegion = "VISIT_REGION"
    case exploreDistance = "EXPLORE_DISTANCE"
    case exploreNewRoads = "EXPLORE_NEW_ROADS"
    case reachElevation = "REACH_ELEVATION"
    case completeDistance = "COMPLETE_DISTANCE"
    case completeClimb = "COMPLETE_CLIMB"
    case visitPOI = "VISIT_POI"
    case photoLocation = "PHOTO_LOCATION"
    case writeNote = "WRITE_NOTE"
    case visitMultipleLocations = "VISIT_MULTIPLE_LOCATIONS"
    case returnToStart = "RETURN_TO_START"
    case completeWithFriend = "COMPLETE_WITH_FRIEND"
    case completeRoute = "COMPLETE_ROUTE"
    /// Warrior: effort measured over the whole ride.
    case rideDuration = "RIDE_DURATION"
    case sustainSpeed = "SUSTAIN_SPEED"
    /// The world: something placed for this player to beat, open or gather.
    case slayMonster = "SLAY_MONSTER"
    case openChest = "OPEN_CHEST"
    case collect = "COLLECT"
    case unknown = "UNKNOWN"
}

public enum ObjectiveStatus: String, SafeEnum {
    case pending = "PENDING"
    case completed = "COMPLETED"
    case skipped = "SKIPPED"
    case unknown = "UNKNOWN"
}

public enum Difficulty: String, SafeEnum {
    case easy = "EASY"
    case moderate = "MODERATE"
    case hard = "HARD"
    case epic = "EPIC"
    case unknown = "UNKNOWN"
}

public enum BikeType: String, SafeEnum {
    case road = "ROAD"
    case gravel = "GRAVEL"
    case mountain = "MOUNTAIN"
    case hybrid = "HYBRID"
    case folding = "FOLDING"
    case other = "OTHER"
    case unknown = "UNKNOWN"
}

public enum RideStatus: String, SafeEnum {
    case recording = "RECORDING"
    case uploaded = "UPLOADED"
    case processing = "PROCESSING"
    case processed = "PROCESSED"
    case flagged = "FLAGGED"
    case discarded = "DISCARDED"
    case unknown = "UNKNOWN"
}

public enum Visibility: String, SafeEnum {
    case privateOnly = "PRIVATE"
    case friends = "FRIENDS"
    case publicAll = "PUBLIC"
    case unknown = "UNKNOWN"
}

public enum BatteryMode: String, SafeEnum {
    case full = "FULL"
    case balanced = "BALANCED"
    case endurance = "ENDURANCE"
    case unknown = "UNKNOWN"
}

public enum MapStyle: String, SafeEnum {
    case minimal = "MINIMAL"
    case cycling = "CYCLING"
    case adventure = "ADVENTURE"
    case detailed = "DETAILED"
    case unknown = "UNKNOWN"
}

public enum StravaUploadMode: String, SafeEnum {
    case auto = "AUTO"
    case ask = "ASK"
    case never = "NEVER"
    case unknown = "UNKNOWN"
}

public enum DiscoveryCategory: String, SafeEnum {
    case nature = "NATURE"
    case historical = "HISTORICAL"
    case cultural = "CULTURAL"
    case food = "FOOD"
    case pub = "PUB"
    case cafe = "CAFE"
    case viewpoint = "VIEWPOINT"
    case cycling = "CYCLING"
    case landmark = "LANDMARK"
    case trail = "TRAIL"
    case custom = "CUSTOM"
    case unknown = "UNKNOWN"
}

public enum InstructionSign: String, SafeEnum {
    case `continue` = "CONTINUE"
    case slightLeft = "SLIGHT_LEFT"
    case left = "LEFT"
    case sharpLeft = "SHARP_LEFT"
    case slightRight = "SLIGHT_RIGHT"
    case right = "RIGHT"
    case sharpRight = "SHARP_RIGHT"
    case uTurn = "U_TURN"
    case roundabout = "ROUNDABOUT"
    case finish = "FINISH"
    case waypoint = "WAYPOINT"
    case unknown = "UNKNOWN"
}

public enum FriendshipState: String, SafeEnum {
    case none = "NONE"
    case requestSent = "REQUEST_SENT"
    case requestReceived = "REQUEST_RECEIVED"
    case friends = "FRIENDS"
    case blocked = "BLOCKED"
    case unknown = "UNKNOWN"
}

public enum PartyStatus: String, SafeEnum {
    case forming = "FORMING"
    case ready = "READY"
    case active = "ACTIVE"
    case completed = "COMPLETED"
    case cancelled = "CANCELLED"
    case unknown = "UNKNOWN"
}

public enum CellState: String, SafeEnum {
    case unseen = "UNSEEN"
    case discovered = "DISCOVERED"
    case visited = "VISITED"
    case explored = "EXPLORED"
    case unknown = "UNKNOWN"

    /// Ordering used when merging server and local knowledge: a cell never
    /// regresses to a lower state.
    public var rank: Int {
        switch self {
        case .unseen, .unknown: return 0
        case .discovered: return 1
        case .visited: return 2
        case .explored: return 3
        }
    }
}

public enum Units: String, SafeEnum {
    case metric = "METRIC"
    case imperial = "IMPERIAL"
    case unknown = "UNKNOWN"
}

public enum DiscoverySource: String, SafeEnum {
    case osm = "OSM"
    case curated = "CURATED"
    case user = "USER"
    case unknown = "UNKNOWN"
}

public enum FeedEventType: String, SafeEnum {
    case friendQuestCompleted = "FRIEND_QUEST_COMPLETED"
    case friendDiscovery = "FRIEND_DISCOVERY"
    case friendLevelUp = "FRIEND_LEVEL_UP"
    case friendNewRegion = "FRIEND_NEW_REGION"
    case unknown = "UNKNOWN"
}

public enum CompletionRule: String, SafeEnum {
    case individual = "INDIVIDUAL"
    case group = "GROUP"
    case unknown = "UNKNOWN"
}

public enum LevelKind: String, SafeEnum {
    case overall = "OVERALL"
    case classLevel = "CLASS"
    case unknown = "UNKNOWN"
}

public enum DevicePlatform: String, SafeEnum {
    case ios = "IOS"
    case watchOS = "WATCHOS"
    case unknown = "UNKNOWN"
}

public enum APNSEnvironment: String, SafeEnum {
    case sandbox = "SANDBOX"
    case production = "PRODUCTION"
    case unknown = "UNKNOWN"
}
