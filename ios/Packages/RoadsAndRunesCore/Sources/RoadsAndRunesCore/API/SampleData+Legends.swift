import Foundation

/// Legends, lairs and treasure maps (0.8.0), for previews, the mock and tests.
/// The words are placeholders in the server's style; the author writes the real ones.
public extension SampleData {
    static let legendId = UUID(uuidString: "c0ffee00-0000-4000-8000-00000000d001")!
    static let lairId = UUID(uuidString: "c0ffee00-0000-4000-8000-00000000d002")!
    static let treasureId = UUID(uuidString: "c0ffee00-0000-4000-8000-00000000d003")!

    /// Where the sample legend lives: about 2.4 km north-east of the origin.
    static let legendPlace = GeoMath.destination(from: origin, bearingDegrees: 45, distanceMeters: 2400)

    /// The Fog Dragon in its second phase: the first broken over two journeys, 140 off the second.
    static let sampleLegend = Legend(
        id: legendId, speciesId: "fog-dragon", name: "The Fog Dragon", icon: "fogDragon",
        flavour: "A dragon that sleeps where the map is blank.",
        page: "The Fog Dragon curls up on ground nobody has explored. Explore the tiles round it and it has nowhere to hide.",
        latitude: legendPlace.latitude, longitude: legendPlace.longitude, anchorName: "Stave Hill",
        status: LegendStatus.awake, phase: 2,
        phases: [
            LegendPhase(n: 1, weakTo: ["GROUND"], resists: ["WORD"], healthMax: 500, healthLeft: 0, broken: true),
            LegendPhase(n: 2, weakTo: ["GROUND", "ROAD"], resists: ["WORD"], healthMax: 500, healthLeft: 360),
            LegendPhase(n: 3, weakTo: ["RUNE"], resists: ["WORD"], healthMax: 500, healthLeft: 500),
        ],
        healthLeft: 860, healthMax: 1500, moved: false,
        wokeAt: referenceDate.addingTimeInterval(-9 * 86_400), lastHitAt: referenceDate.addingTimeInterval(-2 * 86_400),
        healsPerWeek: 50, sleepsAfterDays: 28, rune: "hagalaz",
        journeys: [
            LegendJourney(rideId: "66666666-6666-4666-8666-666666666601", date: referenceDate.addingTimeInterval(-8 * 86_400), damage: 320, phase: 1),
            LegendJourney(rideId: "66666666-6666-4666-8666-666666666602", date: referenceDate.addingTimeInterval(-5 * 86_400), damage: 180, phase: 1),
            LegendJourney(rideId: "66666666-6666-4666-8666-666666666603", date: referenceDate.addingTimeInterval(-2 * 86_400), damage: 140, phase: 2),
        ]
    )

    /// One seen off before: the Hill King.
    static let sampleDefeatedLegend = LegendSummary(
        id: UUID(uuidString: "c0ffee00-0000-4000-8000-00000000d004")!, speciesId: "hill-king", name: "The Hill King", icon: "hillKing",
        flavour: "A king who sits on the highest hill and waits to be climbed.",
        page: "The Hill King likes a climb. Go up his hill and he gives way.", status: LegendStatus.defeated, rune: "uruz",
        defeatedAt: referenceDate.addingTimeInterval(-30 * 86_400)
    )

    static let sampleLegends = LegendsState(awake: sampleLegend, defeated: [sampleDefeatedLegend], creaturesUntilNext: nil)

    /// The seven tiles of a lair round `centre`: its own, then the six round it.
    static func lairCells(round centre: Coordinate, spacingMeters: Double = 300) -> [[Double]] {
        [[centre.latitude, centre.longitude]] + stride(from: 0.0, to: 360.0, by: 60.0).map { bearing in
            let point = GeoMath.destination(from: centre, bearingDegrees: bearing, distanceMeters: spacingMeters)
            return [point.latitude, point.longitude]
        }
    }

    /// A lair round a park about 1.5 km south-west: three of seven tiles visited, five needed.
    static func sampleLair(endsAt: Date = referenceDate.addingTimeInterval(9 * 86_400)) -> WorldObject {
        let centre = GeoMath.destination(from: origin, bearingDegrees: 225, distanceMeters: 1500)
        var lair = WorldObject(id: lairId, kind: .unknown, latitude: centre.latitude, longitude: centre.longitude, name: "Southwark Park lair",
                               anchorName: "Southwark Park", rewardAC: 250, expiresAt: endsAt)
        lair.lair = LairInfo(cells: lairCells(round: centre), visited: [0, 2, 5], need: 5, endsAt: endsAt)
        return lair
    }

    static let sampleClue = TreasureClue(treasureId: treasureId, clue: "Buried by water, in a green place, about 2 km north-east of here.",
                                         buriedAt: referenceDate)

    /// A journey that broke the Fog Dragon's second phase.
    static let sampleLegendOutcome = LegendOutcome(
        id: legendId, speciesId: "fog-dragon", name: "The Fog Dragon", icon: "fogDragon", phaseBefore: 2, phaseAfter: 3,
        healthLeft: 500, healthMax: 1500, phaseHealthLeft: 500, phaseHealthMax: 500,
        damage: 360, kinds: ["GROUND": 240, "ROAD": 120], phaseBroken: true, defeated: false,
        rewards: LegendRewards(coins: 150, xp: 300, items: [
            ItemFound(kind: "GEAR", itemId: "rowan-twig", name: "Rowan Twig", icon: "rowanTwig", rarity: "RARE", slot: "KEEPSAKE",
                      source: "LEGEND", fromName: "The Fog Dragon"),
            ItemFound(kind: "CONSUMABLE", consumable: "TREASURE_MAP", name: "Treasure map", icon: "treasureMap", source: "LEGEND",
                      fromName: "The Fog Dragon"),
        ]),
        line: "Phase broken! The Fog Dragon is down to its last phase."
    )

    static let sampleLairOutcome = LairOutcome(name: "Southwark Park lair", visited: 5, need: 5, done: true,
                                               rewards: LairRewards(coins: 250, item: ItemFound(kind: "GEAR", itemId: "tinkers-satchel",
                                                                                               name: "Tinker's Satchel", icon: "tinkersSatchel",
                                                                                               rarity: "RARE", slot: "BAG", source: "LAIR"),
                                                                    rune: RunePaid(rune: "ingwaz", name: "Ingwaz")))

    static let sampleTreasureFound = TreasureFound(treasureId: treasureId, coins: 120,
                                                   item: ItemFound(kind: "GEAR", itemId: "drovers-bell", name: "Drover's Bell", icon: "droversBell",
                                                                   rarity: "RARE", slot: "BELL", source: "TREASURE"),
                                                   line: "You found the buried treasure!")
}
