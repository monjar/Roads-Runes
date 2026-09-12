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

    public init(
        questTitle: String?, instructions: [Instruction], objectives: [WatchObjective], totalDistanceMeters: Double,
        routeCoordinates: [[Double]] = [], stops: [WatchStop] = []
    ) {
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

    public init(id: UUID, name: String, latitude: Double, longitude: Double, requested: Bool) {
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

    public init(
        state: NavigationState, instruction: Instruction? = nil, distanceToInstructionMeters: Double? = nil,
        nextInstructionText: String? = nil, objectiveTitle: String? = nil, objectiveDistanceMeters: Double? = nil,
        distanceMeters: Double, elapsedSeconds: Double, elevationGainMeters: Double, heartRate: Int? = nil,
        speedMps: Double? = nil, latitude: Double? = nil, longitude: Double? = nil, timestamp: Date = Date()
    ) {
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

    public init(title: String, xp: Int? = nil) {
        self.title = title
        self.xp = xp
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

    /// Dictionary key holding the kind's raw value.
    public static let kindKey = "kind"
    /// Dictionary key holding the JSON-encoded payload (`Data`).
    public static let payloadKey = "payload"
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
}
