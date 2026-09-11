import Foundation
import Network
import Observation
import RoadsAndRunesCore

/// Uploads ride data when the network allows and replays anything that
/// failed. The ride itself never depends on this succeeding (spec §71).
@MainActor
@Observable
final class SyncService {
    enum Kind: String { case points, cells, questProgress, rideComplete }

    private struct Envelope: Codable {
        var rideId: UUID?
        var questId: UUID?
        var points: [RidePoint]?
        var cells: [String]?
        var events: [ObjectiveEvent]?
        var completion: RideComplete?
    }

    var latestSummary: AdventureSummary?
    private(set) var isOnline = true
    private(set) var pendingCount = 0
    private(set) var isPolling = false

    private let api: any RoadsAndRunesAPI
    private let persistence: PersistenceService
    private let session: SessionStore
    private let analytics: AnalyticsSink
    private let monitor = NWPathMonitor()
    private var replaying = false

    init(api: any RoadsAndRunesAPI, persistence: PersistenceService, session: SessionStore, analytics: AnalyticsSink) {
        self.api = api
        self.persistence = persistence
        self.session = session
        self.analytics = analytics
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let cameOnline = online && !self.isOnline
                self.isOnline = online
                if cameOnline { await self.resumePendingUploads() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.roadsandrunes.sync.network"))
    }

    // MARK: Enqueue

    func uploadPoints(rideId: UUID?, rideClientId: UUID, points: [RidePoint]) async {
        guard !points.isEmpty else { return }
        await perform(kind: .points, rideClientId: rideClientId, envelope: Envelope(rideId: rideId, points: points))
    }

    func uploadCells(rideId: UUID?, rideClientId: UUID, cells: [String]) async {
        guard !cells.isEmpty else { return }
        await perform(kind: .cells, rideClientId: rideClientId, envelope: Envelope(rideId: rideId, cells: cells))
    }

    func reportQuestProgress(questId: UUID, rideClientId: UUID, events: [ObjectiveEvent]) async {
        guard !events.isEmpty else { return }
        await perform(kind: .questProgress, rideClientId: rideClientId, envelope: Envelope(questId: questId, events: events))
    }

    func completeRide(rideId: UUID?, rideClientId: UUID, completion: RideComplete) async {
        await perform(kind: .rideComplete, rideClientId: rideClientId, envelope: Envelope(rideId: rideId, completion: completion))
    }

    private func perform(kind: Kind, rideClientId: UUID, envelope: Envelope) async {
        do {
            try await send(kind: kind, envelope: envelope)
        } catch {
            AppLog.sync.warning("upload_deferred kind=\(kind.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            if let data = try? JSONCoding.encode(envelope) {
                persistence.enqueue(kind: kind.rawValue, rideClientId: rideClientId, payload: data)
                pendingCount = persistence.pendingUploads().count
            }
        }
    }

    private func send(kind: Kind, envelope: Envelope) async throws {
        switch kind {
        case .points:
            guard let rideId = envelope.rideId, let points = envelope.points else { throw APIError.invalidURL }
            _ = try await api.uploadRidePoints(id: rideId, RidePointsBatch(points: points))
        case .cells:
            guard let rideId = envelope.rideId, let cells = envelope.cells else { throw APIError.invalidURL }
            _ = try await api.uploadRideExploration(id: rideId, RideCellsBatch(cellsVisited: cells))
        case .questProgress:
            guard let questId = envelope.questId, let events = envelope.events else { throw APIError.invalidURL }
            _ = try await api.reportQuestProgress(id: questId, events: events)
        case .rideComplete:
            guard let rideId = envelope.rideId, let completion = envelope.completion else { throw APIError.invalidURL }
            _ = try await api.completeRide(id: rideId, completion)
            analytics.track(.rideCompleted, properties: ["rideId": rideId.uuidString])
            Task { await self.pollSummary(rideId: rideId) }
        }
    }

    // MARK: Replay

    func resumePendingUploads() async {
        guard !replaying else { return }
        replaying = true
        defer { replaying = false }
        for upload in persistence.pendingUploads() {
            guard let kind = Kind(rawValue: upload.kind), let envelope = try? JSONCoding.decode(Envelope.self, from: upload.payload) else {
                persistence.remove(upload)
                continue
            }
            do {
                try await send(kind: kind, envelope: envelope)
                persistence.remove(upload)
            } catch {
                upload.attempts += 1
                upload.lastError = error.localizedDescription
                persistence.save()
                if upload.attempts > 50 { persistence.remove(upload) }
                if let apiError = error as? APIError, case .network = apiError { break }  // still offline; try later
            }
        }
        pendingCount = persistence.pendingUploads().count
    }

    // MARK: Summary polling (spec §40)

    func pollSummary(rideId: UUID, maxAttempts: Int = 40) async {
        isPolling = true
        defer { isPolling = false }
        var lastFailure: String?
        for _ in 0..<maxAttempts {
            do {
                if let summary = try await api.rideSummary(id: rideId) {
                    latestSummary = summary
                    await session.refreshCharacter()
                    if !summary.levelUps.isEmpty { analytics.track(.levelUp, properties: ["rideId": rideId.uuidString]) }
                    if summary.newCells > 0 { analytics.track(.newAreaExplored, properties: ["cells": String(summary.newCells)]) }
                    return
                }
            } catch {
                // "Not ready yet" is a nil summary; an error (offline, or a response that no
                // longer decodes) is logged once per distinct message so it cannot hide.
                let message = String(describing: error)
                if message != lastFailure {
                    lastFailure = message
                    AppLog.sync.error("summary_poll_failed ride=\(rideId.uuidString, privacy: .public) error=\(message, privacy: .public)")
                }
            }
            try? await Task.sleep(for: .seconds(3))
        }
        AppLog.sync.warning("summary_poll_timeout ride=\(rideId.uuidString, privacy: .public)")
    }
}
