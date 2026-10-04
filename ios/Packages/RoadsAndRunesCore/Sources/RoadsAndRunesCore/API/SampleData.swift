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
        title: "Familiar Face", abilities: sampleAbilities, unspentAbilityPoints: 1, createdAt: referenceDate
    )

    public static let sampleClasses: [ClassInfo] = [
        ClassInfo(id: "EXPLORER", name: "Explorer", tagline: "Goes first. Moves the edge of the map.",
                  description: "The Wayfinders went ahead and decided where the road would go. New roads, new ground and places nobody pointed you at pay best.",
                  enabled: true, guild: "the Wayfinders", saying: "The edge moves.", crest: "explorer"),
        ClassInfo(id: "WIZARD", name: "Wizard", tagline: "Cuts the runes again. Looks twice.",
                  description: "The Cutters kept the runes legible. Old stones, odd markers and shapes drawn with your own track pay best.",
                  enabled: true, guild: "the Cutters", saying: "Look twice, then once more.", crest: "wizard"),
        ClassInfo(id: "WARRIOR", name: "Warrior", tagline: "Keeps the road with the legs. Pays the hill.",
                  description: "The Menders carried the stone. Distance, height and long hours out pay best, measured against yourself.",
                  enabled: true, guild: "the Menders", saying: "The hill does not negotiate.", crest: "warrior"),
        ClassInfo(id: "SCRIBE", name: "Scribe", tagline: "Stops, looks, writes it down.",
                  description: "The Clerks kept the toll-book and everything else. Notes, photographs and places looked at properly pay best.",
                  enabled: true, guild: "the Clerks", saying: "It may as well be you.", crest: "scribe"),
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
        levelUps: [LevelUp(kind: .overall, from: 7, to: 8)], abilitiesUnlocked: [], titlesUnlocked: ["Wanderer"], flags: [],
        acAwarded: 58, acBreakdown: [ACBreakdownEntry(kind: "RIDE_DISTANCE", ac: 24), ACBreakdownEntry(kind: "NEW_CELLS", ac: 34)], walletBalance: 178
    )

    public static let sampleStats = ExplorationStats(
        cellsVisited: 412, cellsExplored: 130, cellsDiscovered: 900, newTerritoryKm: 96.2, uniqueRoadsKm: 210.4,
        regionsVisited: 7, questsCompleted: 12, discoveriesFound: 30, storyQuestsCompleted: 0,
        totalDistanceMeters: 812_000, totalElevationMeters: 6200, ridesCompleted: 41, averageSpeedMps: 4.6, maxSpeedMps: 14.2
    )

    public static let sampleMonster = WorldObject(
        id: UUID(uuidString: "8A1F0B2C-0000-4000-8000-00000000A001")!, kind: .monster, tier: 2,
        latitude: 51.4952, longitude: -0.0265, name: "Lock Wraith", anchorName: "Southwark Park", bounty: true, rewardAC: 300,
        expiresAt: referenceDate.addingTimeInterval(3 * 86_400),
        monster: MonsterInfo(hp: 200, flavour: "Colder, and it has learned to wait where people slow down.", killMethods: [
            KillMethod(
                method: .pace,
                params: [
                    "windowMeters": .number(1000),
                    "paceSecPerKm": .object(["RIDE": .number(130), "RUN": .number(330), "WALK": .number(660)]),
                    "searchRadiusMeters": .number(1000),
                ],
                hint: "Cover 1000 m at 2:10/km or faster within a kilometre of it."
            ),
            KillMethod(
                method: .rune,
                params: [
                    "shape": .string("TRIANGLE"),
                    "scoreThreshold": .number(0.22),
                    "searchRadiusMeters": .number(1000),
                    "minLengthMeters": .number(300),
                    "maxLengthMeters": .number(4000),
                ],
                hint: "Trace a triangle with your track, within a kilometre of it."
            ),
        ], speciesId: "bog-wraith", sigil: CreatureSigil(body: "wisp", feature: "hood", mark: "reeds"))
    )
    public static let sampleChest = WorldObject(
        id: UUID(uuidString: "8A1F0B2C-0000-4000-8000-00000000A002")!, kind: .chest, tier: 1,
        latitude: 51.4881, longitude: -0.0202, name: "Old chest", anchorName: "Stave Hill", rewardAC: 25,
        expiresAt: referenceDate.addingTimeInterval(3 * 86_400)
    )
    public static let samplePiece = WorldObject(
        id: UUID(uuidString: "8A1F0B2C-0000-4000-8000-00000000A003")!, kind: .collectable, tier: 1,
        latitude: 51.4925, longitude: -0.0340, name: "Ansuz (Road Six)", anchorName: "The Crown", rewardAC: 10,
        expiresAt: referenceDate.addingTimeInterval(3 * 86_400), setId: "RUNES", piece: "Ansuz"
    )
    public static let sampleObjects: [WorldObject] = [sampleMonster, sampleChest, samplePiece]

    // MARK: Codex

    private static func creature(
        _ id: String, _ name: String, _ family: String, _ flavour: String, hint: String, leaves: String,
        wants: [String], minds: String, rune: String? = nil, elders: (String, String), sigil: CreatureSigil,
        state: CodexState, seen: Int = 0, seenOff: Int = 0
    ) -> CodexCreature {
        CodexCreature(
            id: id, name: name, family: family, flavour: flavour, hint: hint, page: flavour, leaves: leaves,
            wants: wants, minds: [minds], rune: rune,
            elders: [
                CodexElder(tier: 2, name: elders.0, flavour: "", seen: seen > 1),
                CodexElder(tier: 3, name: elders.1, flavour: "", seen: false),
            ],
            sigil: sigil, state: state, seenCount: seen, seenOffCount: seenOff,
            firstSeenAt: seen > 0 ? referenceDate : nil, lastSeenOffAt: seenOff > 0 ? referenceDate : nil
        )
    }

    private static func rune(_ id: String, _ name: String, _ order: Int, _ six: String, _ gloss: String, lends: String,
                             form: String? = nil, held: Int = 0) -> CodexRune {
        CodexRune(id: id, name: name, order: order, six: six, gloss: gloss, lends: lends, roadForm: form,
                  state: held > 0 ? .held : .notFound, found: held)
    }

    /// A smaller codex than the server's, with every kind of page in it.
    public static let sampleCodex = Codex(
        chapters: [
            CodexChapter(id: "WORLD", title: "The Old Roads"),
            CodexChapter(id: "CREATURES", title: "Things that settle"),
            CodexChapter(id: "RUNES", title: "Runes"),
            CodexChapter(id: "PEOPLE", title: "People"),
            CodexChapter(id: "PLACES", title: "Places found"),
        ],
        entries: [
            CodexEntry(id: "the-old-roads", chapter: "WORLD", title: "The Old Roads", body: [
                "Every road was written once. The people who made them cut a rune where two ways met.",
                "People still use the roads. Nobody reads them. A road that is used and not read goes vague. That is the fog.",
            ], by: "enid-sallow", byName: "Enid Sallow"),
            CodexEntry(id: "the-fog", chapter: "WORLD", title: "The fog",
                       body: ["Ground you have not read. Plenty of people have passed it. That is not the same thing."],
                       by: "enid-sallow", byName: "Enid Sallow"),
            CodexEntry(id: "old-coin", chapter: "WORLD", title: "Old coin",
                       body: ["The roads pay in old coin. Nobody will change it for you."],
                       by: "walter-garth", byName: "Walter Garth"),
            CodexEntry(id: "the-wayfinders", chapter: "PEOPLE", title: "The Wayfinders",
                       body: ["They went ahead and decided where the road would go. Their saying: the edge moves."],
                       by: "enid-sallow", byName: "Enid Sallow", characterClass: "EXPLORER"),
        ],
        creatures: [
            creature("bog-wraith", "Bog Wraith", "WATER", "A cold patch of air that follows the bank.",
                     hint: "Keeps to water and the paths beside it.", leaves: "a cold button", wants: ["GROUND", "WORD"],
                     minds: "CLIMB", elders: ("Lock Wraith", "the Long Cold"),
                     sigil: CreatureSigil(body: "wisp", feature: "hood", mark: "reeds"), state: .met, seen: 3, seenOff: 1),
            creature("fen-troll", "Fen Troll", "WATER", "Sleeps by the water; wakes for footsteps.",
                     hint: "Keeps to water.", leaves: "a bridge nail", wants: ["ROAD", "RUNE"], minds: "WORD", rune: "dagaz",
                     elders: ("Culvert Troll", "Old Arch"), sigil: CreatureSigil(body: "hulk", feature: "horns", mark: "water"),
                     state: .seen, seen: 1),
            creature("rook-lord", "Rook Lord", "GREEN", "Holds the green by the sheer number of rooks.",
                     hint: "Keeps to parks and gardens.", leaves: "a black feather", wants: ["GROUND", "WORD"], minds: "CLIMB",
                     elders: ("Rook Baron", "the Parliament"), sigil: CreatureSigil(body: "bird", feature: "crown", mark: "tree"),
                     state: .unseen),
            creature("grey-stag", "Grey Stag", "GREEN", "Stands in the mist and dares you.",
                     hint: "Keeps to high places.", leaves: "a tine", wants: ["CLIMB", "RUNE"], minds: "WORD", rune: "kenaz",
                     elders: ("Grey Hart", "the Grey Royal"), sigil: CreatureSigil(body: "beast", feature: "antlers", mark: "mist"),
                     state: .unseen),
        ],
        runes: [
            rune("fehu", "Fehu", 1, "TRADE", "The toll-rune. What a road is owed.", lends: "coin"),
            rune("ansuz", "Ansuz", 4, "ROAD", "The word-rune. A place named is a place kept.", lends: "the word", form: "NOTE", held: 1),
            rune("raido", "Raido", 5, "ROAD", "The road-rune. Cut it again and the way remembers you.", lends: "the road", form: "LOOP", held: 2),
            rune("kenaz", "Kenaz", 6, "ROAD", "The torch. It shows what is there, which is not always welcome.", lends: "sight", form: "TRIANGLE"),
            rune("wunjo", "Wunjo", 8, "ROAD", "The glad rune. Roads were also for going somewhere pleasant.", lends: "a stop", form: "STOP"),
            rune("sowilo", "Sowilo", 16, "ROAD", "The sun. A road goes somewhere; this is the somewhere.", lends: "a rune's reach", form: "ZIGZAG"),
            rune("dagaz", "Dagaz", 23, "ROAD", "The day-rune. Dawn and dusk are the same mark seen from each side.", lends: "the day's first outing", form: "SQUARE"),
        ],
        sixes: [
            CodexSix(id: "ROAD", name: "the Road Six", how: "Found lying anywhere. Rune-stones work loose."),
            CodexSix(id: "TRADE", name: "the Trade Six", how: "Given by the trades, at the end of a chapter."),
        ],
        people: [
            CodexPerson(id: "ada-pym", name: "Ada Pym", role: "Keeps the board", posts: "ANY",
                        page: "Pins what needs looking at and does not say who told her.", pageBy: "enid-sallow",
                        lines: ["Wanted: somebody. The park, north side. Up since Tuesday."]),
            CodexPerson(id: "walter-garth", name: "Walter Garth", role: "Toll-keeper", posts: "SCRIBE",
                        page: "Keeps the book: every coin in and every coin out.", pageBy: "enid-sallow",
                        lines: ["Nothing is yours until it is in the book."]),
        ],
        counts: CodexCounts(creaturesSeenOff: 1, creaturesSeen: 2, creaturesTotal: 12, runesHeld: 2, runesTotal: 24)
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
        featureFlags: ["fog_of_war": false, "story_quests": false, "codex": true],
        objects: sampleObjects
    )

    // MARK: Social & meta

    public static let sampleFriend = FriendSummary(id: friendId, displayName: "Bea", characterClass: .explorer, overallLevel: 5, title: "Familiar Face", since: referenceDate)

    public static let sampleParty = Party(
        id: partyId, ownerId: userId, questId: questId, routeId: nil, status: .forming, completionRule: .group,
        members: [
            PartyMember(user: FriendSummary(id: userId, displayName: "Amir", characterClass: .explorer, overallLevel: 8), role: "OWNER", status: "READY"),
            PartyMember(user: sampleFriend, role: "MEMBER", status: "INVITED"),
        ],
        createdAt: referenceDate
    )

    public static let sampleStoryArcs: [StoryArc] = [
        StoryArc(
            slug: "first-light",
            title: "First Light",
            description: "Nobody starts out knowing the roads. They start by going outside, and then a little further than last time.",
            minLevel: 1,
            unlocked: true,
            quests: [
                StoryStep(slug: "first-light-out-of-the-door", sequence: 1, title: "Out of the Door",
                          description: "The hardest part of any outing is the first hundred metres.", state: .completed),
                StoryStep(slug: "first-light-something-green", sequence: 2, title: "Something Green",
                          description: "Every town keeps a green place, and most people pass the turning for years.", state: .open, questId: questId),
                StoryStep(slug: "first-light-somewhere-to-look-from", sequence: 3, title: "Somewhere to Look From",
                          description: "Ground you have read looks different from above it.", state: .locked),
            ],
            track: "MAIN", act: 1, actTitle: "The Board", chapter: 1, giver: "ada-pym",
            reward: StoryStanding.Reward(title: "Early Riser", ac: 100)
        ),
        StoryArc(
            slug: "what-settles",
            title: "What Settles",
            description: "A road used and not read goes vague, and things settle in the vague parts. Not wicked; in the way.",
            minLevel: 1,
            unlocked: false,
            quests: [
                StoryStep(slug: "what-settles-something-in-the-way", sequence: 1, title: "Something in the Way",
                          description: "One on the board with a name and a place.", state: .ready),
                StoryStep(slug: "what-settles-a-box-nobody-came-back-for", sequence: 2, title: "A Box Nobody Came Back For",
                          description: "A waywright buried it when the gate closed.", state: .locked),
                StoryStep(slug: "what-settles-three-patches", sequence: 3, title: "Three Patches",
                          description: "Three patches of unread ground within reach.", state: .locked),
            ],
            track: "MAIN", act: 1, actTitle: "The Board", chapter: 2, after: "first-light", giver: "ada-pym",
            reward: StoryStanding.Reward(title: "Somebody", ac: 150)
        ),
        StoryArc(
            slug: "the-edge-of-the-map",
            title: "The Edge of the Map",
            description: "A Wayfinder's map has an edge, and the edge moves. This is the work of moving it.",
            characterClass: .explorer,
            minLevel: 2,
            unlocked: true,
            quests: [
                StoryStep(slug: "edge-of-the-map-past-the-fog", sequence: 1, title: "Past the Fog",
                          description: "Ways you have never taken, and enough of them to be sure it was deliberate.", state: .waiting,
                          waitingReason: "Waiting for unread ground within reach."),
            ],
            track: "SIDE", giver: "nell-foss", reward: StoryStanding.Reward(title: "Edgewalker", ac: 200)
        ),
    ]

    public static let sampleTitles: [TitleInfo] = [
        TitleInfo(slug: "level-1", name: "Passer-by", source: "LEVEL", how: "Go out once.", earned: true, earnedAt: referenceDate),
        TitleInfo(slug: "level-5", name: "Familiar Face", source: "LEVEL", how: "Reach level 5.", earned: true, earnedAt: referenceDate, worn: true),
        TitleInfo(slug: "arc-first-light", name: "Early Riser", source: "ARC", how: "Finish First Light.", earned: false),
        TitleInfo(slug: "level-10", name: "Roadwise", source: "LEVEL", how: "Reach level 10.", earned: false),
    ]

    public static let sampleWeekNotice = WeekNotice(
        week: "2026-W41", kind: "OUTINGS", title: "Three outings this week.", line: "Pinned Monday. Comes down Sunday night.",
        postedBy: "Ada Pym", target: 3, unit: "outings", progress: 1, done: false, paid: false, coins: 150, xp: 200,
        endsAt: referenceDate.addingTimeInterval(4 * 86_400)
    )

    public static let sampleConfig = AppConfig(
        featureFlags: ["fog_of_war": false, "story_quests": false, "party_quests": false, "strava": false,
                       "wizard_class": true, "warrior_class": true, "scribe_class": true, "codex": true],
        h3Resolution: 9, levels: LevelLimits(max: 50, maxClass: 30), environment: "preview"
    )
}
