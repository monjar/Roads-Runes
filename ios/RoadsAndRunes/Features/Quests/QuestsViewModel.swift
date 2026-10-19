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
    /// This week's notice (0.6.2); nil from a server before it.
    private(set) var weekNotice: WeekNotice?
    /// The festival's arc while its window is open (0.9.0); nil between festivals.
    private(set) var seasonArc: StoryArc?
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
            async let weekTask = try? container.api.weekNotice()
            async let arcsTask = try? container.api.storyArcs()
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
            weekNotice = await weekTask
            seasonArc = (await arcsTask)?.first { $0.isSeason && $0.unlocked && ($0.endsAt.map { $0 > Date() } ?? true) }
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
    /// Where the quest's route stands: a quest with a bare map and nothing to say
    /// why looked broken, so the map always says which of these it is.
    enum RouteState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// The quest's route from where the player is (spec §20), drawn on the detail map; tweakable in the planner.
    private(set) var route: RouteOption?
    private(set) var routeState: RouteState = .idle
    private(set) var routeCamera: MapCamera?
    /// A stop on the quest route that the rider tapped on the map.
    private(set) var focusedStop: RoutePOI?

    /// Ways to ride it (a loop, one way, the long way…), fetched once the route is drawn.
    enum WaysState: Equatable { case idle, loading, loaded, failed }
    private(set) var ways: [QuestWay] = []
    private(set) var wayNotes: [String] = []
    private(set) var waysState: WaysState = .idle
    /// The way picked on this screen, shown at once; `confirmedWayId` is the one the server has.
    private(set) var chosenWayId: UUID?
    private var confirmedWayId: UUID?
    /// Counts taps, so only the last one's answer is acted on.
    private var choiceGeneration = 0
    private(set) var isChoosingWay = false
    /// A short line under the chips when a way could not be taken.
    private(set) var wayError: String?
    /// Where the route was asked from, so the ways start from the same place.
    private var routeOrigin: Coordinate?
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

    private static let mapPadding = UIEdgeInsets(top: 110, left: 36, bottom: 64, right: 36)

    /// The route starts where the player is standing, so it is asked for with their
    /// position; the server draws it again if they have moved since it was last drawn.
    func loadRoute() async {
        guard route == nil, routeState != .loading else { return }
        routeState = .loading
        let here = await firstPosition()
        routeOrigin = here
        // Until it arrives the map shows the player and where the quest goes, not an empty square.
        let overview = (here.map { [$0] } ?? []) + targets
        if overview.count >= 2 { routeCamera = MapCamera(fit: overview, padding: Self.mapPadding) }
        do {
            let fixed = try await container.api.questRoute(id: quest.id, from: here)
            route = fixed
            routeCamera = MapCamera(fit: fixed.path, padding: Self.mapPadding)
            routeState = .loaded
            // Its distance, and the way home, moved with the route.
            await refresh()
        } catch {
            routeState = .failed(error.localizedDescription)
        }
    }

    func retryRoute() async {
        route = nil
        routeState = .idle
        await loadRoute()
        await loadWays()
    }

    /// The board picks a sealed quest's way (0.7.3), and a quest under way or done keeps its own.
    var offersWays: Bool {
        !SealedQuest.isSealed(quest) && (quest.status == .available || quest.status == .accepted)
    }

    /// The other ways to ride it, after the route: slow on the server, and the route alone
    /// is enough to go on, so a failure here is kept quiet.
    func loadWays() async {
        guard offersWays, waysState == .idle || waysState == .failed else { return }
        waysState = .loading
        do {
            let result = try await container.api.questWays(id: quest.id, from: routeOrigin ?? position)
            ways = result.ways
            wayNotes = result.notes
            let chosen = result.chosenRouteId.flatMap { id in result.ways.first { $0.route.id == id } }
                ?? route.flatMap { drawn in result.ways.first { $0.route.id == drawn.id } }
                ?? result.ways.first
            chosenWayId = chosen?.route.id
            confirmedWayId = chosenWayId
            // The map and the tiles follow the chip that is lit.
            if let chosen, chosen.route.id != route?.id { draw(chosen.route) }
            waysState = .loaded
        } catch {
            waysState = .failed
        }
    }

    /// Draws the way at once, then tells the server; if it says no, the last way it agreed to comes back.
    func choose(_ way: QuestWay) async {
        guard way.route.id != chosenWayId else { return }
        choiceGeneration += 1
        let generation = choiceGeneration
        chosenWayId = way.route.id
        wayError = nil
        draw(way.route)
        UISelectionFeedbackGenerator().selectionChanged()
        isChoosingWay = true
        do {
            let updated = try await container.api.chooseQuestWay(id: quest.id, routeId: way.route.id)
            guard generation == choiceGeneration else { return }
            quest = updated
            confirmedWayId = way.route.id
            isChoosingWay = false
            container.analytics.track(.routeSelected, properties: [
                "questId": quest.id.uuidString, "routeId": way.route.id.uuidString, "questWay": way.kind.rawValue,
            ])
        } catch {
            guard generation == choiceGeneration else { return }
            isChoosingWay = false
            chosenWayId = confirmedWayId
            if let confirmed = ways.first(where: { $0.route.id == confirmedWayId }) { draw(confirmed.route) }
            wayError = "Couldn't take that road just now. Try again in a moment."
        }
    }

    private func draw(_ newRoute: RouteOption) {
        route = newRoute
        routeState = .loaded
        focusedStop = nil
        routeCamera = MapCamera(fit: newRoute.path, padding: Self.mapPadding)
    }

    /// The crow's flight from the player through the quest's places, drawn dashed
    /// while there is no route to draw.
    var guide: [Coordinate] {
        guard route == nil, let position, !targets.isEmpty else { return [] }
        return [position] + targets
    }

    private var targets: [Coordinate] {
        quest.sortedObjectives.filter { $0.objectiveType != .returnToStart }.compactMap(\.coordinate)
    }

    /// A quest opened the moment the app is may not have a fix yet; a second is worth
    /// waiting for a route that starts in the right place.
    private func firstPosition() async -> Coordinate? {
        for _ in 0..<10 where position == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return position
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
