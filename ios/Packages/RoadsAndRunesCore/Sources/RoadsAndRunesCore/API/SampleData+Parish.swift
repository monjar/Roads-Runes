import Foundation

/// The parish (0.9.0) for previews, the mock and tests: districts round the
/// origin, a year's Atlas, a festival's arc and the looks. The titles follow the
/// server's rules; the words are placeholders in its style.
public extension SampleData {
    static let rotherhitheId = "c0ffee00-0000-4000-8000-00000000e001"
    static let bermondseyId = "c0ffee00-0000-4000-8000-00000000e002"
    static let surreyDocksId = "c0ffee00-0000-4000-8000-00000000e003"
    static let deptfordId = "c0ffee00-0000-4000-8000-00000000e004"

    /// Rotherhithe: yours, its roads known. Bermondsey: 47%, close to yours. Surrey Docks:
    /// was yours. Deptford: passed once, in the fog, its roads not yet known.
    static let sampleDistricts: [District] = [
        District(id: rotherhitheId, name: "Rotherhithe", kind: "suburb", title: "the Riverlands", displayName: "Rotherhithe, the Riverlands",
                 percent: 62, exploredTiles: 41, wayTiles: 66, yours: true, weeklyCoins: 5,
                 latitude: origin.latitude + 0.008, longitude: origin.longitude - 0.01,
                 firstPassed: referenceDate.addingTimeInterval(-60 * 86_400), lastPassed: referenceDate.addingTimeInterval(-86_400)),
        District(id: bermondseyId, name: "Bermondsey", kind: "suburb", title: "the Market Quarter", displayName: "Bermondsey, the Market Quarter",
                 percent: 47, exploredTiles: 30, wayTiles: 64, weeklyCoins: 5,
                 latitude: origin.latitude + 0.006, longitude: origin.longitude - 0.035,
                 firstPassed: referenceDate.addingTimeInterval(-40 * 86_400), lastPassed: referenceDate.addingTimeInterval(-3 * 86_400)),
        District(id: surreyDocksId, name: "Surrey Docks", kind: "neighbourhood", title: "the Greenwood", displayName: "Surrey Docks, the Greenwood",
                 percent: 55, exploredTiles: 22, wayTiles: 40, wasYours: true, weeklyCoins: 5,
                 latitude: origin.latitude - 0.004, longitude: origin.longitude + 0.005,
                 firstPassed: referenceDate.addingTimeInterval(-90 * 86_400), lastPassed: referenceDate.addingTimeInterval(-45 * 86_400)),
        District(id: deptfordId, name: "Deptford", kind: "town", displayName: "Deptford, in the fog",
                 exploredTiles: 4, weeklyCoins: 5,
                 latitude: origin.latitude - 0.012, longitude: origin.longitude + 0.012,
                 firstPassed: referenceDate.addingTimeInterval(-10 * 86_400), lastPassed: referenceDate.addingTimeInterval(-10 * 86_400)),
    ]

    static let sampleLedger = DistrictLedger(placesFound: 7, creaturesDefeated: 4, runesCut: 1, questsDone: 3,
                                             firstPassed: referenceDate.addingTimeInterval(-60 * 86_400),
                                             lastPassed: referenceDate.addingTimeInterval(-86_400))

    /// A journey's districts: Bermondsey made yours, Rotherhithe a few new tiles.
    static let sampleDistrictOutcomes: [DistrictOutcome] = [
        DistrictOutcome(id: bermondseyId, name: "Bermondsey", title: "the Market Quarter", percent: 51, newTiles: 3, becameYours: true),
        DistrictOutcome(id: rotherhitheId, name: "Rotherhithe", title: "the Riverlands", percent: 64, newTiles: 2),
    ]

    static let sampleDistrictPay = DistrictPay(coins: 5, districts: ["Rotherhithe"])

    /// This year so far: three journeys over two days and a first or two.
    static let sampleAtlas: Atlas = {
        let loop = Polyline.encode(sampleLoop)
        let out = Polyline.encode([origin, GeoMath.destination(from: origin, bearingDegrees: 60, distanceMeters: 2500)])
        return Atlas(
            traces: [
                AtlasTrace(rideId: rideId, activity: "RIDE", date: "2026-10-03", polyline: loop),
                AtlasTrace(rideId: UUID(uuidString: "66666666-6666-4666-8666-666666666611"), activity: "WALK", date: "2026-10-03", polyline: out),
                AtlasTrace(rideId: UUID(uuidString: "66666666-6666-4666-8666-666666666612"), activity: "RUN", date: "2026-09-28", polyline: out),
            ],
            days: [
                AtlasDay(date: "2026-09-28", journeys: 1, distanceMeters: 5000),
                AtlasDay(date: "2026-10-03", journeys: 2, distanceMeters: 27_400),
            ],
            year: AtlasYear(journeys: 3, distanceMeters: 32_400, newTiles: 58, creaturesDefeated: 6, legendsDefeated: 0, runesCut: 1,
                            districtsYours: 1, deedsReached: ["Wayfarer"],
                            firsts: [
                                AtlasFirst(kind: "FIRST_CREATURE", date: "2026-09-28", text: "First creature defeated: Fen Troll"),
                                AtlasFirst(kind: "LONGEST_JOURNEY", date: "2026-10-03", text: "Longest journey: 22.4 km"),
                            ])
        )
    }()

    /// Midsummer's arc, two weeks open from the festival day: one step done.
    static func sampleSeasonArc(endsAt: Date) -> StoryArc {
        StoryArc(
            slug: "season-midsummer", title: "Midsummer", description: "The longest day. Get out and make the most of it.",
            minLevel: 1, unlocked: true,
            quests: [
                StoryStep(slug: "midsummer-1", sequence: 1, title: "A Green Place", description: "Ride to a park or a wood.", state: .completed),
                StoryStep(slug: "midsummer-2", sequence: 2, title: "The Festival Chest", description: "Open a chest.", state: .open),
                StoryStep(slug: "midsummer-3", sequence: 3, title: "The Midsummer Creature", description: "Defeat a creature.", state: .locked),
            ],
            track: "SEASON", reward: StoryStanding.Reward(rune: "fehu"), season: "MIDSUMMER", endsAt: endsAt
        )
    }

    /// The looks owned: the free ones everyone has, Sage ink and the Rope frame from the
    /// stall, and a deed's crest frame.
    static let sampleCosmetics: [Cosmetic] = [
        Cosmetic(itemId: "ink:ink", kind: "INK", name: "Ink", color: "#2E2A24", source: "DEFAULT"),
        Cosmetic(itemId: "ink:sage", kind: "INK", name: "Sage", color: "#7A8A5E", source: "STALL"),
        Cosmetic(itemId: "marker:plain", kind: "MARKER_FRAME", name: "Plain", source: "DEFAULT"),
        Cosmetic(itemId: "marker:rope", kind: "MARKER_FRAME", name: "Rope", source: "STALL"),
        Cosmetic(itemId: "crest:plain", kind: "CREST_FRAME", name: "Plain", source: "DEFAULT"),
        Cosmetic(itemId: "crest:legs-1", kind: "CREST_FRAME", name: "Wayfarer", source: "DEED"),
    ]

    static let sampleLook = Look(ink: "ink:ink", markerFrame: "marker:plain", crestFrame: "crest:plain")

    /// The stall's fifth offer (0.9.0): one look a week.
    static let sampleCosmeticOffer = StallOffer(
        id: "w41-4", kind: "COSMETIC", itemId: "ink:wizard-blue", name: "Wizard Blue", icon: "paintbrush",
        text: "Your journeys drawn in a wizard's blue.", price: 300, cosmeticKind: "INK", color: "#3D5A99"
    )
}
