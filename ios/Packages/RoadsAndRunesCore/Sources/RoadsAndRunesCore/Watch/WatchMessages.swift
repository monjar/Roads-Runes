import Foundation

// Message DTOs exchanged between the iPhone `RideRecorder` and the Watch app
// over WatchConnectivity (docs/WATCH.md). Payloads travel as JSON `Data` under
// a `kind` discriminator so both sides only depend on this file.

/// A quest objective reduced to what the Watch shows.
public struct WatchObjective: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var latitude: Double?
    public var longitude: Double?

    public init(id: UUID, title: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(objective: Objective) {
        self.init(id: objective.id, title: objective.title, latitude: objective.latitude, longitude: objective.longitude)
    }

    public var coordinate: Coordinate? {
        guard let latitude = latitude, let longitude = longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}

/// Sent once when a ride starts (`transferUserInfo`).
public struct WatchRouteSummary: Codable, Hashable, Sendable {
    public var questTitle: String?
    public var instructions: [Instruction]
    public var objectives: [WatchObjective]
    public var totalDistanceMeters: Double
    /// The route to draw on the Watch, thinned to what a 45 mm screen can show.
    /// GeoJSON order (`[lon, lat]`), same as `RouteOption.coordinates`.
    public var routeCoordinates: [[Double]]
    /// Stops the rider asked for, so the Watch map can show what they are riding to.
    public var stops: [WatchStop]
    /// RIDE | RUN | WALK, so the Watch starts the right kind of workout. Optional:
    /// a Watch build from before activities still decodes the summary.
    public var activity: String?
    /// The game near the route (0.7.2): creatures, chests and rune stones within
    /// reach of it, at most `WatchWorldMarks.limit`, then each objective's place.
    /// An older phone sends none and the Watch map shows only the route.
    public var worldMarks: [WatchWorldMark]?

    public init(
        questTitle: String?, instructions: [Instruction], objectives: [WatchObjective], totalDistanceMeters: Double,
        routeCoordinates: [[Double]] = [], stops: [WatchStop] = [], activity: String? = nil, worldMarks: [WatchWorldMark]? = nil
    ) {
        self.worldMarks = worldMarks
        self.activity = activity
        self.questTitle = questTitle
        self.instructions = instructions
        self.objectives = objectives
        self.totalDistanceMeters = totalDistanceMeters
        self.routeCoordinates = routeCoordinates
        self.stops = stops
    }

    public var path: [Coordinate] { routeCoordinates.compactMap { Coordinate(geoJSON: $0) } }
}

/// A stop on the Watch map: what it is called and where, nothing more.
public struct WatchStop: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var requested: Bool
    /// What kind of place it is ("PUB", "VIEWPOINT"…), so it draws as its place
    /// mark (0.7.2). An older phone sends none and the stop is a plain dot.
    public var category: String?

    public init(id: UUID, name: String, latitude: Double, longitude: Double, requested: Bool, category: String? = nil) {
        self.category = category
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.requested = requested
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

/// Sent on every throttled update (`sendMessage` when reachable, otherwise
/// `updateApplicationContext` so the Watch always has the latest state).
public struct WatchNavigationUpdate: Codable, Hashable, Sendable {
    public var state: NavigationState
    public var instruction: Instruction?
    public var distanceToInstructionMeters: Double?
    public var nextInstructionText: String?
    public var objectiveTitle: String?
    public var objectiveDistanceMeters: Double?
    public var distanceMeters: Double
    public var elapsedSeconds: Double
    public var elevationGainMeters: Double
    public var heartRate: Int?
    public var speedMps: Double?
    /// Where the rider is, so the Watch map can follow without its own GPS.
    public var latitude: Double?
    public var longitude: Double?
    public var timestamp: Date
    /// "Bog Wraith · 120 m · pace 60%": the nearest thing in the world, if any.
    public var encounterLine: String?
    /// Metres ridden on ground new to the rider, so far this ride.
    public var newTerritoryMeters: Double?
    /// How far is left of the route.
    public var remainingMeters: Double?
    /// Which way the rider is heading, in degrees from north (CourseTracker), so
    /// the Watch map's dot points the way they are going. An older phone sends none.
    public var courseDegrees: Double?
    /// The fight to draw on the Quest page (0.7.2): the quarry, else the nearest
    /// creature being fought. Nil when nothing is being fought, or from an older phone.
    public var fight: WatchFight?
    /// World marks (and objective places) opened, defeated or done on this ride,
    /// all of them so far, so the Watch map can take them off. Nil from an older phone.
    public var goneMarkIds: [UUID]?
    /// The district the rider is in, with its title (0.9.0): "Rotherhithe, the
    /// Riverlands" or "Rotherhithe, in the fog". The Watch names each one once a
    /// journey, at a standstill (`DistrictNaming`, by `speedMps`), never while
    /// moving. Nil while the phone does not know, and from an older phone.
    public var districtName: String?

    public init(
        state: NavigationState, instruction: Instruction? = nil, distanceToInstructionMeters: Double? = nil,
        nextInstructionText: String? = nil, objectiveTitle: String? = nil, objectiveDistanceMeters: Double? = nil,
        distanceMeters: Double, elapsedSeconds: Double, elevationGainMeters: Double, heartRate: Int? = nil,
        speedMps: Double? = nil, latitude: Double? = nil, longitude: Double? = nil, timestamp: Date = Date(),
        encounterLine: String? = nil, newTerritoryMeters: Double? = nil, remainingMeters: Double? = nil,
        courseDegrees: Double? = nil, fight: WatchFight? = nil, goneMarkIds: [UUID]? = nil, districtName: String? = nil
    ) {
        self.districtName = districtName
        self.fight = fight
        self.goneMarkIds = goneMarkIds
        self.courseDegrees = courseDegrees
        self.encounterLine = encounterLine
        self.newTerritoryMeters = newTerritoryMeters
        self.remainingMeters = remainingMeters
        self.state = state
        self.instruction = instruction
        self.distanceToInstructionMeters = distanceToInstructionMeters
        self.nextInstructionText = nextInstructionText
        self.objectiveTitle = objectiveTitle
        self.objectiveDistanceMeters = objectiveDistanceMeters
        self.distanceMeters = distanceMeters
        self.elapsedSeconds = elapsedSeconds
        self.elevationGainMeters = elevationGainMeters
        self.heartRate = heartRate
        self.speedMps = speedMps
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
    }

    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
}

/// Fired when a client-side objective completes (Watch plays a success haptic).
public struct WatchObjectiveCompleted: Codable, Hashable, Sendable {
    public var title: String
    public var xp: Int?
    /// Coins the thing was worth, for "+60 coins" under the title. Optional so an older
    /// Watch build still reads the message.
    public var coins: Int?
    /// A second line: "Road Six, 3 of 6".
    public var detail: String?
    /// What happened, for the overlay's heading: GONE, OPENED, FOUND or DONE.
    /// Optional: an older phone sends none and the Watch falls back.
    public var outcome: String?
    /// The thing's mark as a `GameIcon` raw name: the creature defeated, or an item
    /// found (0.7.2). An older phone sends none and the outcome picks the mark.
    public var icon: String?
    /// An item found (outcome FOUND): COMMON, RARE or LEGENDARY.
    public var rarity: String?

    public init(title: String, xp: Int? = nil, coins: Int? = nil, detail: String? = nil, outcome: String? = nil,
                icon: String? = nil, rarity: String? = nil) {
        self.title = title
        self.xp = xp
        self.coins = coins
        self.detail = detail
        self.outcome = outcome
        self.icon = icon
        self.rarity = rarity
    }

    /// An item found on the way ("Tin Bell", a Common bell), for the overlay.
    public static func found(name: String, icon: String?, rarity: String?, detail: String? = nil) -> WatchObjectiveCompleted {
        WatchObjectiveCompleted(title: name, detail: detail, outcome: "FOUND", icon: icon, rarity: rarity)
    }
}

/// Watch → iPhone ride controls.
public enum WatchCommand: String, Codable, CaseIterable, Hashable, Sendable {
    case pause
    case resume
    case end
}

/// Watch → iPhone heart-rate sample from the Watch workout session.
public struct WatchHeartRateSample: Codable, Hashable, Sendable {
    public var bpm: Int
    public var timestamp: Date

    public init(bpm: Int, timestamp: Date = Date()) {
        self.bpm = bpm
        self.timestamp = timestamp
    }
}

/// Discriminator stored under `WatchMessageKind.kindKey` in every message.
public enum WatchMessageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case routeSummary
    case navigationUpdate
    case objectiveCompleted
    case command
    case heartRate
    /// A fight beat to feel on the wrist (0.6.1). Older Watch builds ignore it.
    case encounterBeat
    /// Journey's end, once the server has counted the journey (0.7.2). Older
    /// Watch builds ignore it.
    case journeyEnd
    /// Watch → iPhone: plan this and start it (0.7.3). An older phone ignores it.
    case startRequest
    /// iPhone → Watch: what came of a start request (0.7.3). An older Watch ignores it.
    case startResult

    /// Dictionary key holding the kind's raw value.
    public static let kindKey = "kind"
    /// Dictionary key holding the JSON-encoded payload (`Data`).
    public static let payloadKey = "payload"
    /// Application-context key holding the JSON-encoded `WatchIdleInfo` (0.7.3),
    /// beside whatever ride message the context carries. An older Watch never looks.
    public static let idleInfoKey = "idleInfo"
}

public enum WatchMessageError: Error, Hashable, Sendable {
    case missingKind
    case unknownKind(String)
    case missingPayload
    case kindMismatch(expected: WatchMessageKind, actual: WatchMessageKind)
}

/// Encode/decode helpers between typed DTOs and the `[String: Any]`
/// dictionaries WatchConnectivity transports.
public enum WatchMessages {
    public static func encode<T: Encodable>(_ kind: WatchMessageKind, _ value: T) throws -> [String: Any] {
        let data = try JSONCoding.encode(value)
        return [WatchMessageKind.kindKey: kind.rawValue, WatchMessageKind.payloadKey: data]
    }

    public static func kind(of message: [String: Any]) -> WatchMessageKind? {
        guard let raw = message[WatchMessageKind.kindKey] as? String else { return nil }
        return WatchMessageKind(rawValue: raw)
    }

    public static func decode<T: Decodable>(_ type: T.Type, as expected: WatchMessageKind, from message: [String: Any]) throws -> T {
        guard let raw = message[WatchMessageKind.kindKey] as? String else { throw WatchMessageError.missingKind }
        guard let actual = WatchMessageKind(rawValue: raw) else { throw WatchMessageError.unknownKind(raw) }
        guard actual == expected else { throw WatchMessageError.kindMismatch(expected: expected, actual: actual) }
        guard let data = message[WatchMessageKind.payloadKey] as? Data else { throw WatchMessageError.missingPayload }
        return try JSONCoding.decode(type, from: data)
    }

    // MARK: Typed conveniences

    public static func routeSummary(_ summary: WatchRouteSummary) throws -> [String: Any] {
        try encode(.routeSummary, summary)
    }

    public static func navigationUpdate(_ update: WatchNavigationUpdate) throws -> [String: Any] {
        try encode(.navigationUpdate, update)
    }

    public static func objectiveCompleted(_ event: WatchObjectiveCompleted) throws -> [String: Any] {
        try encode(.objectiveCompleted, event)
    }

    public static func command(_ command: WatchCommand) throws -> [String: Any] {
        try encode(.command, command)
    }

    public static func heartRate(_ sample: WatchHeartRateSample) throws -> [String: Any] {
        try encode(.heartRate, sample)
    }

    public static func encounterBeat(_ beat: WatchEncounterBeat) throws -> [String: Any] {
        try encode(.encounterBeat, beat)
    }

    public static func journeyEnd(_ end: WatchJourneyEnd) throws -> [String: Any] {
        try encode(.journeyEnd, end)
    }

    public static func routeSummary(from message: [String: Any]) throws -> WatchRouteSummary {
        try decode(WatchRouteSummary.self, as: .routeSummary, from: message)
    }

    public static func navigationUpdate(from message: [String: Any]) throws -> WatchNavigationUpdate {
        try decode(WatchNavigationUpdate.self, as: .navigationUpdate, from: message)
    }

    public static func objectiveCompleted(from message: [String: Any]) throws -> WatchObjectiveCompleted {
        try decode(WatchObjectiveCompleted.self, as: .objectiveCompleted, from: message)
    }

    public static func command(from message: [String: Any]) throws -> WatchCommand {
        try decode(WatchCommand.self, as: .command, from: message)
    }

    public static func heartRate(from message: [String: Any]) throws -> WatchHeartRateSample {
        try decode(WatchHeartRateSample.self, as: .heartRate, from: message)
    }

    public static func encounterBeat(from message: [String: Any]) throws -> WatchEncounterBeat {
        try decode(WatchEncounterBeat.self, as: .encounterBeat, from: message)
    }

    public static func journeyEnd(from message: [String: Any]) throws -> WatchJourneyEnd {
        try decode(WatchJourneyEnd.self, as: .journeyEnd, from: message)
    }

    public static func startRequest(_ request: WatchStartRequest) throws -> [String: Any] {
        try encode(.startRequest, request)
    }

    public static func startRequest(from message: [String: Any]) throws -> WatchStartRequest {
        try decode(WatchStartRequest.self, as: .startRequest, from: message)
    }

    public static func startResult(_ result: WatchStartResult) throws -> [String: Any] {
        try encode(.startResult, result)
    }

    public static func startResult(from message: [String: Any]) throws -> WatchStartResult {
        try decode(WatchStartResult.self, as: .startResult, from: message)
    }

    // MARK: The application context (0.7.3)

    /// The application context to send: the ride's last message, if a journey is
    /// under way, with Next up beside it. The context is replaced whole on every
    /// send, so neither may push the other out.
    public static func context(ride: [String: Any]?, idle: WatchIdleInfo?) throws -> [String: Any] {
        var context = ride ?? [:]
        if let idle {
            context[WatchMessageKind.idleInfoKey] = try JSONCoding.encode(idle)
        } else {
            context.removeValue(forKey: WatchMessageKind.idleInfoKey)
        }
        return context
    }

    /// Next up, if the message (an application context) carries it.
    public static func idleInfo(from message: [String: Any]) -> WatchIdleInfo? {
        guard let data = message[WatchMessageKind.idleInfoKey] as? Data else { return nil }
        return try? JSONCoding.decode(WatchIdleInfo.self, from: data)
    }
}
