import Foundation
import RoadsAndRunesCore
import SwiftData

/// Thin wrapper over the SwiftData container. All access is on the main actor.
@MainActor
final class PersistenceService {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) {
        let schema = Schema([LocalActiveRide.self, LocalRidePoint.self, PendingUpload.self, CachedQuest.self])
        let url = AppContainer.storageDirectory().appendingPathComponent("local.store")
        let configuration = inMemory
            ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            : ModelConfiguration(schema: schema, url: url)
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A corrupt store must not brick the app; fall back to memory and log.
            AppLog.sync.error("swiftdata_container_failed \(error.localizedDescription, privacy: .public)")
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        }
    }

    func save() {
        do { try context.save() } catch { AppLog.sync.error("swiftdata_save_failed \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Rides

    func upsertActiveRide(clientRideId: UUID, serverRideId: UUID?, questId: UUID?, routeId: UUID?, bikeId: UUID?, startedAt: Date, state: NavigationState) {
        if let existing = activeRide(clientRideId: clientRideId) {
            existing.serverRideId = serverRideId ?? existing.serverRideId
            existing.navigationState = state.rawValue
        } else {
            context.insert(LocalActiveRide(clientRideId: clientRideId, serverRideId: serverRideId, questId: questId, routeId: routeId, bikeId: bikeId, startedAt: startedAt, navigationState: state.rawValue))
        }
        save()
    }

    func activeRide(clientRideId: UUID) -> LocalActiveRide? {
        let descriptor = FetchDescriptor<LocalActiveRide>(predicate: #Predicate { $0.clientRideId == clientRideId })
        return try? context.fetch(descriptor).first
    }

    func deleteActiveRide(clientRideId: UUID) {
        if let ride = activeRide(clientRideId: clientRideId) { context.delete(ride) }
        for point in points(rideClientId: clientRideId) { context.delete(point) }
        save()
    }

    func append(fix: LocationFix, rideClientId: UUID, sequence: Int) {
        context.insert(LocalRidePoint(rideClientId: rideClientId, sequence: sequence, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude, timestamp: fix.timestamp, altitude: fix.altitude, horizontalAccuracy: fix.horizontalAccuracy, speed: fix.speed, heartRate: fix.heartRate))
    }

    func points(rideClientId: UUID, onlyPending: Bool = false) -> [LocalRidePoint] {
        var descriptor = FetchDescriptor<LocalRidePoint>(
            predicate: onlyPending ? #Predicate { $0.rideClientId == rideClientId && $0.uploaded == false } : #Predicate { $0.rideClientId == rideClientId },
            sortBy: [SortDescriptor(\.sequence)]
        )
        descriptor.fetchLimit = 50_000
        return (try? context.fetch(descriptor)) ?? []
    }

    func pointCount(rideClientId: UUID) -> Int {
        (try? context.fetchCount(FetchDescriptor<LocalRidePoint>(predicate: #Predicate { $0.rideClientId == rideClientId }))) ?? 0
    }

    func markUploaded(_ points: [LocalRidePoint]) {
        for point in points { point.uploaded = true }
        save()
    }

    // MARK: Pending uploads

    func enqueue(kind: String, rideClientId: UUID?, payload: Data) {
        context.insert(PendingUpload(kind: kind, rideClientId: rideClientId, payload: payload))
        save()
    }

    func pendingUploads() -> [PendingUpload] {
        let descriptor = FetchDescriptor<PendingUpload>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func remove(_ upload: PendingUpload) {
        context.delete(upload)
        save()
    }

    // MARK: Quest cache

    func cache(quests: [Quest]) {
        for quest in quests {
            guard let data = try? JSONCoding.encode(quest) else { continue }
            let id = quest.id
            if let existing = try? context.fetch(FetchDescriptor<CachedQuest>(predicate: #Predicate { $0.id == id })).first {
                existing.json = data
                existing.fetchedAt = Date()
            } else {
                context.insert(CachedQuest(id: quest.id, json: data))
            }
        }
        save()
    }

    func cachedQuests() -> [Quest] {
        let rows = (try? context.fetch(FetchDescriptor<CachedQuest>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]))) ?? []
        return rows.compactMap { try? JSONCoding.decode(Quest.self, from: $0.json) }
    }
}
