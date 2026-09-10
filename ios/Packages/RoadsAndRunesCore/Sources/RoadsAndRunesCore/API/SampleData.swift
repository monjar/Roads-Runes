import Foundation

/// Deterministic sample data for previews and tests.
public enum SampleData {
    public static let userId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    public static let characterId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    public static let bikeId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    public static let questId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    public static let routeId = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    public static let rideId = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    public static let clientRideId = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    public static let discoveryId = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    public static let friendId = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    public static let partyId = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    public static let objectiveVisitId = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    public static let objectiveDistanceId = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
    public static let objectiveReturnId = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!

    /// 2026-01-01T00:00:00Z
    public static let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)
    public static let origin = Coordinate(latitude: 51.49, longitude: -0.04)

    // MARK: Geometry helpers

    /// A closed square loop starting at its south-west corner, running north,
    /// east, south, then west back to the start. `pointsPerSide` points on each
    /// side plus a closing point equal to the first.
    public static func squareLoop(center: Coordinate, sideMeters: Double, pointsPerSide: Int) -> [Coordinate] {
        let half = sideMeters / 2
        let southWest = GeoMath.destination(from: GeoMath.destination(from: center, bearingDegrees: 180, distanceMeters: half), bearingDegrees: 270, distanceMeters: half)
        let corners = [
            southWest,
            GeoMath.destination(from: southWest, bearingDegrees: 0, distanceMeters: sideMeters),
        ]
        let northEast = GeoMath.destination(from: corners[1], bearingDegrees: 90, distanceMeters: sideMeters)
        let southEast = GeoMath.destination(from: northEast, bearingDegrees: 180, distanceMeters: sideMeters)
        let loop = [southWest, corners[1], northEast, southEast]
        var points: [Coordinate] = []
        let count = max(1, pointsPerSide)
        for side in 0..<4 {
            let from = loop[side]
            let to = loop[(side + 1) % 4]
            for step in 0..<count {
                let t = Double(step) / Double(count)
                points.append(Coordinate(
                    latitude: from.latitude + (to.latitude - from.latitude) * t,
                    longitude: from.longitude + (to.longitude - from.longitude) * t
                ))
            }
        }
        points.append(southWest)
        return points
    }

    // MARK: Users & character

    public static let sampleUser = User(
        id: userId, displayName: "Amir", avatarUrl: nil, createdAt: referenceDate, hasCharacter: true, settings: UserSettings()
    )

    public static let sampleAbilities: [AbilityState] = [
        AbilityState(
            ability: Ability(id: "explorer_trail_sense", characterClass: .explorer, name: "Trail Sense",
                             description: "Reveal more interesting nearby paths.", requiredClassLevel: 5, maxRank: 3,
                             effects: [AbilityEffect(type: "QUEST_POI_VISIBILITY", perRank: 0.15)]),
            rank: 1, unlocked: true, canUnlock: false
        ),
        AbilityState(
            ability: Ability(id: "explorer_far_sight", characterClass: .explorer, name: "Far Sight",
                             description: "Reveal one extra ring of cells around visited territory.", requiredClassLevel: 3, maxRank: 2,
                             effects: [AbilityEffect(type: "FOG_REVEAL_RADIUS_CELLS", perRank: 1)]),
            rank: 0, unlocked: false, canUnlock: true
        ),
    ]

    public static let sampleCharacter = Character(
        id: characterId, name: "Rowan", characterClass: .explorer,
        overallLevel: 8, overallXP: 1820, nextOverallLevelXP: 2200, overallLevelFloorXP: 1500,
        classLevel: 6, classXP: 900, nextClassLevelXP: 1200, classLevelFloorXP: 700,
        title: "Wanderer", abilities: sampleAbilities, unspentAbilityPoints: 1, createdAt: referenceDate
    )

    public static let sampleClasses: [ClassInfo] = [
        ClassInfo(id: "EXPLORER", name: "Explorer", tagline: "Go where you have never been.", description: "Rewards new territory and discoveries.", enabled: true),
        ClassInfo(id: "WIZARD", name: "Wizard", tagline: "Seek the hidden.", description: "Coming later.", enabled: false),
        ClassInfo(id: "WARRIOR", name: "Warrior", tagline: "Conquer the climbs.", description: "Coming later.", enabled: false),
        ClassInfo(id: "SCRIBE", name: "Scribe", tagline: "Record the world.", description: "Coming later.", enabled: false),
    ]

    public static let sampleBike = Bike(
        id: bikeId, name: "Boardman ADV 8.8", bikeType: .gravel, allowGravel: true, allowTrails: true, maxTechnicalSurface: 2, isDefault: true
    )

    public static let sampleRiderProfile = RiderProfile(
        comfortableDistanceKm: 30, comfortableElevationGain: 400, maxPreferredGradient: 8,
        trafficTolerance: 0.3, gravelComfort: 0.6, technicalTrailComfort: 0.2, cyclewayPreference: 0.8
    )

    // MARK: Quest

    public static let sampleObjectives: [Objective] = [
        Objective(id: objectiveVisitId, objectiveType: .visitLocation, title: "Reach Old Station",
                  latitude: 51.4945, longitude: -0.0350, radiusMeters: 50, required: true, order: 1,
                  progress: ObjectiveProgress(current: 0, target: 1)),
        Objective(id: objectiveDistanceId, objectiveType: .exploreNewRoads, title: "Ride 5 km of new roads",
                  targetMeters: 5000, required: true, order: 2, progress: ObjectiveProgress(current: 0, target: 5000)),
        Objective(id: objectiveReturnId, objectiveType: .returnToStart, title: "Return home",
                  latitude: origin.latitude, longitude: origin.longitude, radiusMeters: 100, required: false, order: 3,
                  progress: ObjectiveProgress(current: 0, target: 1)),
    ]

    public static let sampleQuest = Quest(
        id: questId, questType: "EXPLORE_REGION", characterClass: .explorer, templateId: "EXPLORER_NEW_TERRITORY",
        title: "Beyond the Water", description: "Cross the river and find roads you have never ridden.",
        narrative: QuestNarrative(hook: "The far bank is unmapped in your journal.", completion: "New lines appear on the map."),
        difficulty: .moderate, recommendedDistanceKm: 28, estimatedDurationMinutes: 120, baseXP: 350, status: .available,
        origin: origin, objectives: sampleObjectives, rewards: QuestRewards(xp: 350, items: [], titles: []), createdAt: referenceDate
    )

    // MARK: Route

    public static let sampleLoop: [Coordinate] = squareLoop(center: origin, sideMeters: 600, pointsPerSide: 5)

    public static let sampleInstructions: [Instruction] = {
        let signs: [(Int, InstructionSign, String, String)] = [
            (0, .`continue`, "Head north on Rotherhithe Street", "Rotherhithe Street"),
            (5, .right, "Turn right onto Salter Road", "Salter Road"),
            (10, .right, "Turn right onto Brunel Road", "Brunel Road"),
            (15, .right, "Turn right onto Rotherhithe Street", "Rotherhithe Street"),
            (20, .finish, "Arrive at your destination", "Rotherhithe Street"),
        ]
        return signs.enumerated().map { index, item in
            let coordinate = sampleLoop[item.0]
            return Instruction(
                index: index, text: item.2, streetName: item.3, sign: item.1,
                distanceMeters: item.1 == .finish ? 0 : 600, durationSeconds: item.1 == .finish ? 0 : 150,
                coordinateIndex: item.0, latitude: coordinate.latitude, longitude: coordinate.longitude
            )
        }
    }()

    public static let sampleElevationSamples: [ElevationSample] = {
        let total = GeoMath.pathLength(sampleLoop)
        var samples: [ElevationSample] = []
        var distance = 0.0
        while distance <= total {
            samples.append(ElevationSample(distanceMeters: distance.rounded(), elevationMeters: (22 + 12 * sin(distance / total * 2 * .pi)).rounded()))
            distance += 200
        }
        return samples
    }()

    public static let sampleRoute: RouteOption = {
        let distances = GeoMath.cumulativeDistances(sampleLoop)
        let total = distances.last ?? 0
        let coordinates = sampleLoop.enumerated().map { index, c -> [Double] in
            [c.longitude, c.latitude, (22 + 12 * sin(distances[index] / max(total, 1) * 2 * .pi)).rounded()]
        }
        return RouteOption(
            id: routeId, label: "Adventure", engine: "synthetic", distanceMeters: total.rounded(), estimatedDurationSeconds: 600,
            elevationGainMeters: 24, elevationLossMeters: 24, highestPointMeters: 34, maxGradientPercent: 4.5,
            averageClimbGradientPercent: 2.1, longestClimb: Climb(startMeters: 0, lengthMeters: 600, gainMeters: 12, averageGradientPercent: 2.0),
            surface: SurfaceBreakdown(paved: 0.7, gravel: 0.25, trail: 0.05, unknown: 0), cyclewayFraction: 0.55,
            trafficExposure: 0.2, newTerritoryFraction: 0.62, questObjectiveCoverage: 1.0, score: 0.81,
            pois: [samplePOI], coordinates: coordinates, encodedPolyline: Polyline.encode(sampleLoop),
            instructions: sampleInstructions, elevationSamples: sampleElevationSamples,
            climbs: [Climb(startMeters: 0, lengthMeters: 600, gainMeters: 12, averageGradientPercent: 2.0)],
            boundingBox: BoundingBox.enclosing(sampleLoop), createdAt: referenceDate
        )
    }()

    public static let samplePOI = RoutePOI(
        discoveryId: discoveryId, name: "The Crown", category: .pub, latitude: 51.4915, longitude: -0.0365,
        routePositionMeters: 1800, detourMeters: 60, detourSeconds: 20, estimatedArrivalSeconds: 450
    )

    public static let sampleRoutePackage = RoutePackage(
        route: sampleRoute, quest: sampleQuest, pois: [samplePOI],
        mapRegion: BoundingBox.enclosing(sampleLoop) ?? BoundingBox(minLat: 51.48, minLon: -0.05, maxLat: 51.50, maxLon: -0.03),
        generatedAt: referenceDate
    )

    // MARK: Rides & summary

    public static let sampleRide = Ride(
        id: rideId, clientRideId: clientRideId, status: .processed, title: nil, startedAt: referenceDate,
        endedAt: referenceDate.addingTimeInterval(7480), distanceMeters: 32400, durationSeconds: 7480, movingSeconds: 7000,
        elevationGainMeters: 340, activeCalories: 876, averageSpeedMps: 4.3, maxSpeedMps: 11.2, questId: questId,
        bikeId: bikeId, routeId: routeId, visibility: .privateOnly, pointCount: 1800, flags: [],
        createdAt: referenceDate
    )

    public static let sampleDiscoveries: [DiscoverySummary] = [
        DiscoverySummary(id: discoveryId, name: "The Crown", category: .pub, latitude: 51.4915, longitude: -0.0365, source: .osm, discoveredByUser: false),
        DiscoverySummary(id: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!, name: "Greenwich Foot Tunnel", category: .landmark,
                         latitude: 51.4855, longitude: -0.0100, source: .curated, discoveredByUser: true, discoveredAt: referenceDate),
    ]

    public static let sampleAdventureSummary = AdventureSummary(
        ride: sampleRide, quest: sampleQuest, questCompletion: nil, xpAwarded: 420,
        xpBreakdown: [XPBreakdownEntry(source: "QUEST_COMPLETED", xp: 350), XPBreakdownEntry(source: "CLASS_BONUS", xp: 70)],
        newCells: 34, newTerritoryMeters: 12600, newRoadsMeters: 9800, discoveries: sampleDiscoveries,
        levelUps: [LevelUp(kind: .overall, from: 7, to: 8)], abilitiesUnlocked: [], titlesUnlocked: ["Wanderer"], flags: []
    )

    public static let sampleStats = ExplorationStats(
        cellsVisited: 412, cellsExplored: 130, cellsDiscovered: 900, newTerritoryKm: 96.2, uniqueRoadsKm: 210.4,
        regionsVisited: 7, questsCompleted: 12, discoveriesFound: 30, storyQuestsCompleted: 0,
        totalDistanceMeters: 812_000, totalElevationMeters: 6200, ridesCompleted: 41, averageSpeedMps: 4.6, maxSpeedMps: 14.2
    )

    public static let sampleWorld = WorldSnapshot(
        center: origin, h3Resolution: 9,
        cells: [
            ExplorationCell(h3: "89194ad32c3ffff", state: .visited, firstVisitedAt: referenceDate),
            ExplorationCell(h3: "89194ad32c7ffff", state: .explored, firstVisitedAt: referenceDate),
            ExplorationCell(h3: "89194ad32cbffff", state: .discovered),
        ],
        discoveries: sampleDiscoveries,
        questMarkers: [QuestMarker(questId: questId, title: sampleQuest.title, latitude: 51.5, longitude: -0.02, difficulty: .moderate, questType: "EXPLORE_REGION", status: .available)],
        featureFlags: ["fog_of_war": true, "story_quests": false]
    )

    // MARK: Social & meta

    public static let sampleFriend = FriendSummary(id: friendId, displayName: "Bea", characterClass: .explorer, overallLevel: 5, title: "Pathfinder", since: referenceDate)

    public static let sampleParty = Party(
        id: partyId, ownerId: userId, questId: questId, routeId: nil, status: .forming, completionRule: .group,
        members: [
            PartyMember(user: FriendSummary(id: userId, displayName: "Amir", characterClass: .explorer, overallLevel: 8), role: "OWNER", status: "READY"),
            PartyMember(user: sampleFriend, role: "MEMBER", status: "INVITED"),
        ],
        createdAt: referenceDate
    )

    public static let sampleConfig = AppConfig(
        featureFlags: ["fog_of_war": true, "story_quests": false, "party_quests": false, "strava": false,
                       "wizard_class": false, "warrior_class": false, "scribe_class": false],
        h3Resolution: 9, levels: LevelLimits(max: 50, maxClass: 30), environment: "preview"
    )
}
