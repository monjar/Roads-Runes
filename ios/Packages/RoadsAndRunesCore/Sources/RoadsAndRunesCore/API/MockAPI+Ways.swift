import Foundation

/// Ways to ride a quest: the quest's route as the loop, and others drawn from it.
extension MockAPI {
    public func questWays(id: UUID, from origin: Coordinate?) async throws -> QuestWays {
        try await run {
            let current = try self.currentQuestRoute(id, from: origin)
            let quest = try self.requireQuest(id)
            // A sealed quest's way is the board's to pick: only the one it has.
            if SealedQuest.isSealed(quest) {
                return QuestWays(ways: [QuestWay(kind: .loop, name: "Loop", summary: "The way the board picked", route: current)],
                                 chosenRouteId: current.id)
            }
            let comesHome = quest.objectives.contains { $0.objectiveType == .returnToStart && $0.required }
            if let ways = self.storedWays[id], ways.contains(where: { $0.route.id == current.id }) {
                return QuestWays(ways: ways, chosenRouteId: quest.suggestedRouteId, notes: Self.wayNotes(comesHome: comesHome))
            }
            var loop = current
            loop.questWay = .loop
            var ways = [QuestWay(kind: .loop, name: "Loop", summary: "Out to it and home another way", route: loop)]
            if !comesHome {
                ways.append(QuestWay(kind: .oneWay, name: "One way", summary: "Straight there; find your own way back",
                                     route: Self.firstHalf(of: loop)))
            }
            ways.append(QuestWay(kind: .longWay, name: "The long way", summary: "A wider ring for legs that want more",
                                 bonus: QuestWayBonus(xp: 60, ac: 10, condition: "Ride the whole long way"),
                                 route: Self.variant(of: loop, kind: .longWay, label: "The long way", scale: 1.35) { $0.newTerritoryFraction = 0.7 }))
            ways.append(QuestWay(kind: .newGround, name: "New ground", summary: "Roads your wheels have never touched",
                                 bonus: QuestWayBonus(xp: 40, ac: 5, condition: "Ride it end to end"),
                                 route: Self.variant(of: loop, kind: .newGround, label: "New ground", scale: 1.2) { $0.newTerritoryFraction = 0.92 }))
            ways.append(QuestWay(kind: .quiet, name: "Quiet roads", summary: "Lanes and paths, away from the traffic",
                                 route: Self.variant(of: loop, kind: .quiet, label: "Quiet roads", scale: 1.1) {
                                     $0.trafficExposure = 0.05
                                     $0.cyclewayFraction = 0.85
                                 }))
            for way in ways { self.storedRoutes[way.route.id] = way.route }
            self.storedWays[id] = ways
            return QuestWays(ways: ways, chosenRouteId: quest.suggestedRouteId, notes: Self.wayNotes(comesHome: comesHome))
        }
    }

    /// Like the server: only one of the quest's own ways, and the quest follows it.
    public func chooseQuestWay(id: UUID, routeId: UUID) async throws -> Quest {
        try await run {
            var quest = try self.requireQuest(id)
            guard let way = self.storedWays[id]?.first(where: { $0.route.id == routeId }) else { throw self.notFound("Way") }
            quest.suggestedRouteId = routeId
            quest.recommendedDistanceKm = (way.route.distanceMeters / 100).rounded() / 10
            quest.estimatedDurationMinutes = max(1, way.route.estimatedDurationSeconds / 60)
            self.storedQuests[id] = quest
            return quest
        }
    }

    static func wayNotes(comesHome: Bool) -> [String] {
        comesHome ? ["No one-way here: this quest asks you to come home"] : []
    }

    /// The loop's outward half: where it goes, without the way home.
    static func firstHalf(of loop: RouteOption) -> RouteOption {
        var route = loop
        route.id = UUID()
        route.label = "One way"
        route.questWay = .oneWay
        let cut = max(1, loop.coordinates.count / 2)
        route.coordinates = Array(loop.coordinates.prefix(cut + 1))
        let path = route.path
        route.encodedPolyline = Polyline.encode(path)
        route.distanceMeters = GeoMath.pathLength(path).rounded()
        let share = loop.distanceMeters > 0 ? route.distanceMeters / loop.distanceMeters : 0.5
        route.estimatedDurationSeconds = Int(Double(loop.estimatedDurationSeconds) * share)
        route.instructions = loop.instructions.filter { $0.coordinateIndex <= cut }
        route.elevationSamples = loop.elevationSamples.filter { $0.distanceMeters <= route.distanceMeters }
        route.pois = loop.pois.filter { $0.routePositionMeters <= route.distanceMeters }
        route.climbs = loop.climbs.filter { $0.startMeters <= route.distanceMeters }
        route.boundingBox = BoundingBox.enclosing(path)
        return route
    }

    /// The loop's geometry under another name, longer or shorter by `scale`.
    static func variant(of loop: RouteOption, kind: QuestWayKind, label: String, scale: Double, tweak: (inout RouteOption) -> Void = { _ in }) -> RouteOption {
        var route = loop
        route.id = UUID()
        route.label = label
        route.questWay = kind
        route.distanceMeters = (loop.distanceMeters * scale).rounded()
        route.estimatedDurationSeconds = Int(Double(loop.estimatedDurationSeconds) * scale)
        tweak(&route)
        return route
    }
}
