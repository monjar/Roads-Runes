import Foundation
import SwiftData

/// SwiftData models for local-first state (spec §70). Ride points are stored
/// locally first so a crash or an offline ride never loses the trace.
@Model
final class LocalActiveRide {
    @Attribute(.unique) var clientRideId: UUID
    var serverRideId: UUID?
    var questId: UUID?
    var routeId: UUID?
    var bikeId: UUID?
    var startedAt: Date
    var navigationState: String
    var uploadedPointCount: Int

    init(clientRideId: UUID, serverRideId: UUID? = nil, questId: UUID? = nil, routeId: UUID? = nil, bikeId: UUID? = nil, startedAt: Date, navigationState: String, uploadedPointCount: Int = 0) {
        self.clientRideId = clientRideId
        self.serverRideId = serverRideId
        self.questId = questId
        self.routeId = routeId
        self.bikeId = bikeId
        self.startedAt = startedAt
        self.navigationState = navigationState
        self.uploadedPointCount = uploadedPointCount
    }
}

@Model
final class LocalRidePoint {
    var rideClientId: UUID
    var sequence: Int
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var altitude: Double?
    var horizontalAccuracy: Double?
    var speed: Double?
    var heartRate: Int?
    var uploaded: Bool

    init(rideClientId: UUID, sequence: Int, latitude: Double, longitude: Double, timestamp: Date, altitude: Double? = nil, horizontalAccuracy: Double? = nil, speed: Double? = nil, heartRate: Int? = nil, uploaded: Bool = false) {
        self.rideClientId = rideClientId
        self.sequence = sequence
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.heartRate = heartRate
        self.uploaded = uploaded
    }
}

/// Anything that must reach the server eventually: point batches, cell batches,
/// quest progress, ride completion. Replayed by `SyncService`.
@Model
final class PendingUpload {
    @Attribute(.unique) var id: UUID
    var kind: String
    var rideClientId: UUID?
    var payload: Data
    var createdAt: Date
    var attempts: Int
    var lastError: String?

    init(id: UUID = UUID(), kind: String, rideClientId: UUID? = nil, payload: Data, createdAt: Date = Date(), attempts: Int = 0, lastError: String? = nil) {
        self.id = id
        self.kind = kind
        self.rideClientId = rideClientId
        self.payload = payload
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }
}

@Model
final class CachedQuest {
    @Attribute(.unique) var id: UUID
    var json: Data
    var fetchedAt: Date

    init(id: UUID, json: Data, fetchedAt: Date = Date()) {
        self.id = id
        self.json = json
        self.fetchedAt = fetchedAt
    }
}
