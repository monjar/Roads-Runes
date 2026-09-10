import Foundation

public struct Climb: Codable, Hashable, Sendable {
    public var startMeters: Double
    public var lengthMeters: Double
    public var gainMeters: Double
    public var averageGradientPercent: Double

    public init(startMeters: Double, lengthMeters: Double, gainMeters: Double, averageGradientPercent: Double) {
        self.startMeters = startMeters
        self.lengthMeters = lengthMeters
        self.gainMeters = gainMeters
        self.averageGradientPercent = averageGradientPercent
    }
}

public struct SurfaceBreakdown: Codable, Hashable, Sendable {
    public var paved: Double
    public var gravel: Double
    public var trail: Double
    public var unknown: Double

    public init(paved: Double, gravel: Double, trail: Double, unknown: Double) {
        self.paved = paved
        self.gravel = gravel
        self.trail = trail
        self.unknown = unknown
    }
}

public struct ElevationSample: Codable, Hashable, Sendable {
    public var distanceMeters: Double
    public var elevationMeters: Double

    public init(distanceMeters: Double, elevationMeters: Double) {
        self.distanceMeters = distanceMeters
        self.elevationMeters = elevationMeters
    }
}

public struct Instruction: Codable, Hashable, Identifiable, Sendable {
    public var index: Int
    public var text: String
    public var streetName: String
    public var sign: InstructionSign
    public var distanceMeters: Double
    public var durationSeconds: Int
    public var coordinateIndex: Int
    public var latitude: Double
    public var longitude: Double

    public var id: Int { index }
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(index: Int, text: String, streetName: String, sign: InstructionSign, distanceMeters: Double, durationSeconds: Int, coordinateIndex: Int, latitude: Double, longitude: Double) {
        self.index = index
        self.text = text
        self.streetName = streetName
        self.sign = sign
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.coordinateIndex = coordinateIndex
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct RoutePOI: Codable, Hashable, Identifiable, Sendable {
    public var discoveryId: UUID
    public var name: String
    public var category: DiscoveryCategory
    public var latitude: Double
    public var longitude: Double
    public var routePositionMeters: Double
    public var detourMeters: Double
    public var detourSeconds: Int
    public var estimatedArrivalSeconds: Int
    public var relevance: Double?

    public var id: UUID { discoveryId }
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(discoveryId: UUID, name: String, category: DiscoveryCategory, latitude: Double, longitude: Double, routePositionMeters: Double, detourMeters: Double, detourSeconds: Int, estimatedArrivalSeconds: Int, relevance: Double? = nil) {
        self.discoveryId = discoveryId
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.routePositionMeters = routePositionMeters
        self.detourMeters = detourMeters
        self.detourSeconds = detourSeconds
        self.estimatedArrivalSeconds = estimatedArrivalSeconds
        self.relevance = relevance
    }
}

public struct RouteOption: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var engine: String?
    public var distanceMeters: Double
    public var estimatedDurationSeconds: Int
    public var elevationGainMeters: Double
    public var elevationLossMeters: Double
    public var highestPointMeters: Double
    public var maxGradientPercent: Double
    public var averageClimbGradientPercent: Double
    public var longestClimb: Climb?
    public var surface: SurfaceBreakdown
    public var cyclewayFraction: Double
    public var trafficExposure: Double
    public var newTerritoryFraction: Double
    public var questObjectiveCoverage: Double
    public var score: Double
    public var scoreComponents: [String: Double]?
    public var pois: [RoutePOI]
    /// GeoJSON order: `[lon, lat]` or `[lon, lat, ele]`.
    public var coordinates: [[Double]]
    public var encodedPolyline: String
    public var instructions: [Instruction]
    public var elevationSamples: [ElevationSample]
    public var climbs: [Climb]
    public var boundingBox: BoundingBox?
    public var createdAt: Date?

    public init(
        id: UUID, label: String, engine: String? = nil, distanceMeters: Double, estimatedDurationSeconds: Int,
        elevationGainMeters: Double, elevationLossMeters: Double, highestPointMeters: Double, maxGradientPercent: Double,
        averageClimbGradientPercent: Double, longestClimb: Climb? = nil, surface: SurfaceBreakdown, cyclewayFraction: Double,
        trafficExposure: Double, newTerritoryFraction: Double, questObjectiveCoverage: Double, score: Double,
        scoreComponents: [String: Double]? = nil, pois: [RoutePOI], coordinates: [[Double]], encodedPolyline: String,
        instructions: [Instruction], elevationSamples: [ElevationSample], climbs: [Climb], boundingBox: BoundingBox? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.engine = engine
        self.distanceMeters = distanceMeters
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.elevationGainMeters = elevationGainMeters
        self.elevationLossMeters = elevationLossMeters
        self.highestPointMeters = highestPointMeters
        self.maxGradientPercent = maxGradientPercent
        self.averageClimbGradientPercent = averageClimbGradientPercent
        self.longestClimb = longestClimb
        self.surface = surface
        self.cyclewayFraction = cyclewayFraction
        self.trafficExposure = trafficExposure
        self.newTerritoryFraction = newTerritoryFraction
        self.questObjectiveCoverage = questObjectiveCoverage
        self.score = score
        self.scoreComponents = scoreComponents
        self.pois = pois
        self.coordinates = coordinates
        self.encodedPolyline = encodedPolyline
        self.instructions = instructions
        self.elevationSamples = elevationSamples
        self.climbs = climbs
        self.boundingBox = boundingBox
        self.createdAt = createdAt
    }

    /// Route geometry as `Coordinate`s (drops malformed entries).
    public var path: [Coordinate] {
        coordinates.compactMap { Coordinate(geoJSON: $0) }
    }
}

public struct RoutePreferences: Codable, Hashable, Sendable {
    public var trafficAversion: Double
    public var cyclewayPreference: Double
    public var gravelPreference: Double
    public var scenicPreference: Double
    public var hillTolerance: Double

    public init(trafficAversion: Double = 0.7, cyclewayPreference: Double = 0.7, gravelPreference: Double = 0.3, scenicPreference: Double = 0.6, hillTolerance: Double = 0.5) {
        self.trafficAversion = trafficAversion
        self.cyclewayPreference = cyclewayPreference
        self.gravelPreference = gravelPreference
        self.scenicPreference = scenicPreference
        self.hillTolerance = hillTolerance
    }
}

public struct RouteGenerateRequest: Codable, Hashable, Sendable {
    public var origin: Coordinate
    public var destination: Coordinate?
    public var waypoints: [Coordinate]
    public var bikeId: UUID?
    public var questId: UUID?
    public var distanceTargetKm: Double?
    public var loop: Bool?
    public var preferences: RoutePreferences?
    public var request: String?

    public init(origin: Coordinate, destination: Coordinate? = nil, waypoints: [Coordinate] = [], bikeId: UUID? = nil, questId: UUID? = nil, distanceTargetKm: Double? = nil, loop: Bool? = nil, preferences: RoutePreferences? = nil, request: String? = nil) {
        self.origin = origin
        self.destination = destination
        self.waypoints = waypoints
        self.bikeId = bikeId
        self.questId = questId
        self.distanceTargetKm = distanceTargetKm
        self.loop = loop
        self.preferences = preferences
        self.request = request
    }
}

public struct RouteGenerateResponse: Codable, Hashable, Sendable {
    public var alternatives: [RouteOption]
    /// The server returns a loosely-typed dictionary; known keys map onto `RoutePreferences`.
    public var parsedRequest: [String: JSONValue]?
    public var engine: String?

    public init(alternatives: [RouteOption], parsedRequest: [String: JSONValue]? = nil, engine: String? = nil) {
        self.alternatives = alternatives
        self.parsedRequest = parsedRequest
        self.engine = engine
    }

    public var parsedPreferences: RoutePreferences? {
        guard let parsed = parsedRequest else { return nil }
        var prefs = RoutePreferences()
        var any = false
        if let v = parsed["trafficAversion"]?.doubleValue { prefs.trafficAversion = v; any = true }
        if let v = parsed["cyclewayPreference"]?.doubleValue { prefs.cyclewayPreference = v; any = true }
        if let v = parsed["gravelPreference"]?.doubleValue { prefs.gravelPreference = v; any = true }
        if let v = parsed["scenicPreference"]?.doubleValue { prefs.scenicPreference = v; any = true }
        if let v = parsed["hillTolerance"]?.doubleValue { prefs.hillTolerance = v; any = true }
        return any ? prefs : nil
    }
}

/// Everything needed to navigate offline (`GET /routes/{id}/package`).
public struct RoutePackage: Codable, Hashable, Identifiable, Sendable {
    public var route: RouteOption
    public var quest: Quest?
    public var pois: [RoutePOI]
    public var mapRegion: BoundingBox
    public var generatedAt: Date

    public var id: UUID { route.id }

    public init(route: RouteOption, quest: Quest? = nil, pois: [RoutePOI], mapRegion: BoundingBox, generatedAt: Date) {
        self.route = route
        self.quest = quest
        self.pois = pois
        self.mapRegion = mapRegion
        self.generatedAt = generatedAt
    }
}
