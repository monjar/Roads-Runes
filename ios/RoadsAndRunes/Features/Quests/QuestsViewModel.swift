import Foundation
import Observation
import RoadsAndRunesCore
import UIKit

@MainActor
@Observable
final class QuestsViewModel {
    private(set) var active: [Quest] = []
    private(set) var available: [Quest] = []
    private(set) var completed: [Quest] = []
    /// Today's bounty, if the world has been looked at today.
    private(set) var bounty: WorldObject?
    private(set) var isLoading = false
    var error: String?

    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    var units: Units { container.session.units }
    var characterClass: CharacterClass { container.session.character?.characterClass ?? .explorer }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let origin = container.location.lastFix?.coordinate
        do {
            async let activeTask = container.api.quests(near: origin ?? SampleData.origin, status: .active, limit: 5, cursor: nil)
            async let acceptedTask = container.api.quests(near: origin ?? SampleData.origin, status: .accepted, limit: 10, cursor: nil)
            async let completedTask = container.api.quests(near: origin ?? SampleData.origin, status: .completed, limit: 20, cursor: nil)
            async let bountyTask = try? container.api.bounty()
            let (act, acc, comp) = try await (activeTask, acceptedTask, completedTask)
            active = act.items + acc.items
            completed = comp.items
            if let origin {
                available = try await container.api.quests(near: origin, status: .available).items
            } else {
                available = container.persistence.cachedQuests()
            }
            container.persistence.cache(quests: available)
            bounty = await bountyTask
            error = nil
        } catch {
            self.error = error.localizedDescription
            if available.isEmpty { available = container.persistence.cachedQuests() }
        }
    }

    var recommended: [Quest] { available.filter { $0.characterClass == characterClass }.prefix(3).map { $0 } }
    /// Quests for anyone: a class shapes the board, it does not own it.
    var forAnyone: [Quest] { available.filter { $0.characterClass == .any } }
    var story: [Quest] { available.filter { $0.storyQuestId != nil } }
    /// Every quest in hand, whatever list it is shown in — for looking one up by id.
    var all: [Quest] { available + active + completed }
    var party: [Quest] { available.filter { $0.partyId != nil } + active.filter { $0.partyId != nil } }

    func generateMore() async {
        guard let origin = container.location.lastFix?.coordinate else { return }
        _ = try? await container.api.generateQuests(QuestGenerateRequest(latitude: origin.latitude, longitude: origin.longitude, count: 3, request: nil))
        await load()
    }
}

@MainActor
@Observable
final class QuestDetailModel {
    private(set) var quest: Quest
    var error: String?
    private(set) var busy = false
    /// The quest's fixed route (spec §20), drawn on the detail map; tweakable in the planner.
    private(set) var route: RouteOption?
    private(set) var routeCamera: MapCamera?
    /// A stop on the quest route that the rider tapped on the map.
    private(set) var focusedStop: RoutePOI?
    private let container: AppContainer

    init(quest: Quest, container: AppContainer) {
        self.quest = quest
        self.container = container
        container.analytics.track(.questViewed, properties: ["questId": quest.id.uuidString])
    }

    var units: Units { container.session.units }
    var position: Coordinate? { container.location.lastFix?.coordinate }

    func refresh() async {
        if let latest = try? await container.api.quest(id: quest.id) { quest = latest }
    }

    func loadRoute() async {
        guard route == nil, let fixed = try? await container.api.questRoute(id: quest.id) else { return }
        route = fixed
        routeCamera = MapCamera(fit: fixed.path, padding: UIEdgeInsets(top: 110, left: 36, bottom: 64, right: 36))
    }

    func focus(_ poi: RoutePOI?) { focusedStop = poi }

    func accept() async {
        await perform { try await self.container.api.acceptQuest(id: self.quest.id) }
        guard error == nil else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        container.analytics.track(.questAccepted, properties: ["questId": quest.id.uuidString])
    }

    func abandon() async {
        await perform { try await self.container.api.abandonQuest(id: self.quest.id) }
        container.analytics.track(.questAbandoned, properties: ["questId": quest.id.uuidString])
    }

    private func perform(_ action: () async throws -> Quest) async {
        busy = true
        defer { busy = false }
        do {
            quest = try await action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func distance(to objective: Objective) -> Double? {
        guard let position, let target = objective.coordinate else { return nil }
        return GeoMath.distance(position, target)
    }
}
