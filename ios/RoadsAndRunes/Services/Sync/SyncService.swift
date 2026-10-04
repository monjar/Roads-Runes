import Foundation
import Network
import Observation
import RoadsAndRunesCore

/// A ride that has ended and whose summary has not arrived yet: what the phone
/// itself knows about it, to show while the server counts, and enough to ask for
/// the summary again after the app has been closed.
struct PendingReckoning: Codable, Hashable {
    var rideId: UUID?
    var clientRideId: UUID
    var title: String
    var endedAt: Date
    var distanceMeters: Double
    var elapsedSeconds: Double
    var newTerritoryMeters: Double
    /// "Opened: Old chest": what the phone saw taken, which the server may yet overrule.
    var claimed: [String]
    var objectivesDone: Int
    /// Ride, run or walk, so the holding screen says which; nil from a build before it was kept.
    var activity: Activity?
}

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
    /// The ride just ended, until its summary comes. Kept on disk: ending a ride
    /// used to drop the rider on the tabs with nothing, and a summary that arrived
    /// after the app was closed was never seen at all.
    private(set) var pending: PendingReckoning?
    /// The rider chose to carry on while the server counts; the summary still finds them.
    var holdingHidden = false
    /// Asked for two minutes and still not there: it will be in the Journal.
    private(set) var pollTimedOut = false
    private(set) var isOnline = true
    private(set) var pendingCount = 0
    private(set) var isPolling = false

    private let api: any RoadsAndRunesAPI
    private let persistence: PersistenceService
    private let session: SessionStore
    private let analytics: AnalyticsSink
    private let monitor = NWPathMonitor()
    private var replaying = false
    /// Where the pending ride is kept between launches; nil in tests and previews.
    private let pendingURL: URL?
    /// Older than this, a pending ride is not waited for any more: it is in the Journal.
    private static let pendingMaxAge: TimeInterval = 3 * 86_400

    init(api: any RoadsAndRunesAPI, persistence: PersistenceService, session: SessionStore, analytics: AnalyticsSink, pendingURL: URL? = nil) {
        self.api = api
        self.persistence = persistence
        self.session = session
        self.analytics = analytics
        self.pendingURL = pendingURL
        if let pendingURL, let data = try? Data(contentsOf: pendingURL), let saved = try? JSONCoding.decode(PendingReckoning.self, from: data),
           Date().timeIntervalSince(saved.endedAt) < Self.pendingMaxAge {
            pending = saved
            // Not thrown at them on launch: it arrives as the summary when it is ready.
            holdingHidden = true
        }
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
            if pending != nil, pending?.rideId == nil {
                pending?.rideId = rideId
                savePending()
            }
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
        guard !isPolling else { return }
        isPolling = true
        pollTimedOut = false
        defer { isPolling = false }
        var lastFailure: String?
        for _ in 0..<maxAttempts {
            do {
                if let summary = try await api.rideSummary(id: rideId) {
                    latestSummary = summary
                    clearPending()
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
        pollTimedOut = true
    }

    // MARK: The ride just ended

    /// A ride has ended: remember it, and show what the phone knows while the server counts.
    func beginReckoning(_ reckoning: PendingReckoning) {
        pending = reckoning
        holdingHidden = false
        pollTimedOut = false
        savePending()
    }

    /// The app has been opened again with a ride still waiting for its summary.
    func resumeReckoning() async {
        guard let pending, latestSummary == nil else { return }
        if let rideId = pending.rideId {
            await pollSummary(rideId: rideId)
        } else {
            // The ride itself has not reached the server yet; sending it starts the asking.
            await resumePendingUploads()
        }
    }

    /// The summary has been read (or the wait given up on): nothing is pending.
    func dismissReckoning() {
        latestSummary = nil
        clearPending()
    }

    private func clearPending() {
        pending = nil
        holdingHidden = false
        if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
    }

    private func savePending() {
        guard let pendingURL, let pending, let data = try? JSONCoding.encode(pending) else { return }
        try? FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: pendingURL, options: .atomic)
    }
}
