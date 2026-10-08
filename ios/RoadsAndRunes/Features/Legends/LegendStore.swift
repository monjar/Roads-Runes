import Foundation
import Observation
import RoadsAndRunesCore

/// Legends and treasure maps (0.8.0): the legend awake, those defeated, and the
/// treasure map clues still open. The World map, Next up, the Quests tab and the
/// Codex all read it, so a move or a clue shows everywhere at once. A server
/// from before 0.8.0 has none of it, and nothing is shown.
@MainActor
@Observable
final class LegendStore {
    private(set) var state: LegendsState?
    /// The awake legend's page, with the journeys that hurt it.
    private(set) var page: Legend?
    /// Treasure map clues still to follow (one at a time).
    private(set) var clues: [TreasureClue] = []
    private(set) var moving = false
    var error: String?

    @ObservationIgnored private let api: any RoadsAndRunesAPI
    @ObservationIgnored private let worldCache: FileWorldCacheStore?

    init(api: any RoadsAndRunesAPI, worldCache: FileWorldCacheStore? = nil) {
        self.api = api
        self.worldCache = worldCache
    }

    /// The legend awake now, if any.
    var awake: Legend? { state?.awake.flatMap { $0.isAwake ? $0 : nil } }
    var defeated: [LegendSummary] { state?.defeated ?? [] }

    func refresh() async {
        do {
            let fresh = try await api.legends()
            state = fresh
            if let page, page.id != fresh.awake?.id { self.page = nil }
            // Kept with the last world, for a journey started with no signal.
            try? worldCache?.update { world in world.legend = fresh.awake }
        } catch let failure as APIError where failure.isNotFound {
            state = nil
        } catch {
            // Offline: what was there stays.
        }
    }

    /// The legend's page, with its journeys.
    func loadPage(id: UUID) async {
        do {
            page = try await api.legend(id: id)
            error = nil
        } catch {
            if page?.id != id { page = nil }
        }
    }

    /// Its one free move. Returns whether it moved.
    @discardableResult
    func move(_ legend: Legend) async -> Bool {
        guard !moving else { return false }
        moving = true
        defer { moving = false }
        do {
            let moved = try await api.moveLegend(id: legend.id)
            take(moved)
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func refreshClues() async {
        do {
            clues = try await api.treasureClues()
        } catch let failure as APIError where failure.isNotFound {
            clues = []
        } catch {
            // Offline: the clue stays as it was.
        }
    }

    /// A treasure map was just used: its clue is open now.
    func opened(_ clue: TreasureClue) {
        clues.removeAll { $0.id == clue.id }
        clues.insert(clue, at: 0)
    }

    /// A journey's end may have hurt the legend, woken one, or opened the treasure.
    func journeyEnded(_ summary: AdventureSummary) async {
        await refresh()
        if !summary.treasures.isEmpty || !clues.isEmpty { await refreshClues() }
    }

    private func take(_ legend: Legend) {
        var next = state ?? LegendsState()
        // The page keeps its journeys; the list keeps what it had.
        var moved = legend
        if moved.journeys == nil { moved.journeys = page?.journeys }
        next.awake = moved
        state = next
        page = moved
    }
}
