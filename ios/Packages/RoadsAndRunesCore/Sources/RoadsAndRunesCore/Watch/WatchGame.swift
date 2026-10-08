import Foundation

// The game on the wrist (0.7.2): what the Watch map draws of the world, the
// fight on the Quest page, and Journey's end. Messages only grow: every field
// that an older phone or Watch may lack is optional where it is carried
// (`WatchRouteSummary.worldMarks`, `WatchNavigationUpdate.fight`, the
// `journeyEnd` kind), so either side can be a release behind.

/// Something in the world near the route, as the Watch map draws it.
public struct WatchWorldMark: Codable, Hashable, Identifiable, Sendable {
    public static let monster = "MONSTER"
    public static let chest = "CHEST"
    public static let collectable = "COLLECTABLE"
    /// A quest objective's place.
    public static let objective = "OBJECTIVE"
    /// A legend (0.8.0): drawn larger than anything else, with a gold ring.
    public static let legend = "LEGEND"
    /// A lair's middle (0.8.0): its seven tiles are too small for the wrist.
    public static let lair = "LAIR"

    /// The world object's id, the legend's, or the objective's.
    public var id: UUID
    /// MONSTER, CHEST, COLLECTABLE, OBJECTIVE, LEGEND or LAIR; a string, so a kind
    /// added later reaches an older Watch as something it draws plainly rather
    /// than an error (a 0.7.x Watch draws a legend or a lair as a plain token).
    public var kind: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// Its mark as a `GameIcon` raw name; the Watch falls back to the species, then the kind.
    public var icon: String?
    public var speciesId: String?
    public var tier: Int?
    public var bounty: Bool?
    /// The creature this journey was planned for.
    public var quarry: Bool?

    public init(id: UUID, kind: String, name: String, latitude: Double, longitude: Double, icon: String? = nil,
                speciesId: String? = nil, tier: Int? = nil, bounty: Bool? = nil, quarry: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.icon = icon
        self.speciesId = speciesId
        self.tier = tier
        self.bounty = bounty
        self.quarry = quarry
    }

    public init(object: WorldObject, icon: String?, quarry: Bool) {
        self.init(
            id: object.id, kind: Self.kind(of: object), name: object.name, latitude: object.latitude, longitude: object.longitude,
            icon: icon, speciesId: object.monster?.speciesId, tier: object.tier, bounty: object.isBounty ? true : nil,
            quarry: quarry ? true : nil
        )
    }

    /// The kind the Watch draws: a legend as the journey fights it (`Legend.foe`)
    /// and a lair (whose kind this build reads as UNKNOWN) by their own words.
    public static func kind(of object: WorldObject) -> String {
        if object.isLegend { return legend }
        if object.isLair { return lair }
        return object.kind.rawValue
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public var isQuarry: Bool { quarry ?? false }
    public var isBounty: Bool { bounty ?? false }
    public var isLegend: Bool { kind == Self.legend }
}

/// Which world marks go to the Watch with the route summary.
public enum WatchWorldMarks {
    /// Things this near the route are on the Watch map.
    public static let routeReachMeters = 1500.0
    /// With no route to measure from, things this near the start.
    public static let startReachMeters = 2000.0
    /// At most this many things, so the message stays small and the map readable.
    /// Objective places come on top.
    public static let limit = 30

    /// The things in reach of the route (or of the start, with no route), the
    /// quarry first, then the legend (0.8.0), then bounties, then the nearest, at
    /// most `limit` of them; then each objective's place. A lair (0.8.0) goes as
    /// its middle. `icon` names each thing's `GameIcon`: the phone knows the art,
    /// Core does not. The legend comes from `/legends`, not with the world's
    /// objects: the phone adds it as the journey fights it (`Legend.foe`).
    public static func select(
        objects: [WorldObject], route: [Coordinate], start: Coordinate?, objectives: [Objective] = [], quarryId: UUID? = nil,
        icon: (WorldObject) -> String? = { _ in nil }
    ) -> [WatchWorldMark] {
        let path = sampled(route, max: 400)
        let reach = path.count >= 2 ? routeReachMeters : startReachMeters
        let box = path.count >= 2 ? bounds(of: path, padMeters: reach) : nil
        /// How far a thing is from the route (or the start); nil when out of reach.
        func meters(to point: Coordinate) -> Double? {
            let meters: Double
            if path.count >= 2, let box {
                guard box.contains(point) else { return nil }
                meters = distance(from: point, to: path)
            } else if let start {
                meters = GeoMath.distance(start, point)
            } else {
                return nil
            }
            return meters <= reach ? meters : nil
        }
        var near: [(object: WorldObject, meters: Double)] = []
        var seen: Set<UUID> = []
        for object in objects where object.status == .spawned && (object.kind != .unknown || object.isLair) && seen.insert(object.id).inserted {
            if object.id == quarryId {
                near.append((object, 0))
            } else if let meters = meters(to: object.coordinate) {
                near.append((object, meters))
            }
        }
        near.sort { a, b in
            let aFirst = (a.object.id == quarryId, a.object.isLegend, a.object.isBounty)
            let bFirst = (b.object.id == quarryId, b.object.isLegend, b.object.isBounty)
            if aFirst.0 != bFirst.0 { return aFirst.0 }
            if aFirst.1 != bFirst.1 { return aFirst.1 }
            if aFirst.2 != bFirst.2 { return aFirst.2 }
            return a.meters < b.meters
        }
        var marks = near.prefix(limit).map { WatchWorldMark(object: $0.object, icon: icon($0.object), quarry: $0.object.id == quarryId) }
        for objective in objectives {
            guard let place = objective.coordinate else { continue }
            marks.append(WatchWorldMark(id: objective.id, kind: WatchWorldMark.objective, name: objective.title,
                                        latitude: place.latitude, longitude: place.longitude, icon: "flag"))
        }
        return marks
    }

    /// What the Watch map takes off: everything opened, defeated or done on this
    /// journey, sorted so the same set is the same message. A legend seen off has
    /// only broken a phase unless it was its last (0.8.0), so it stays on the map.
    public static func gone(claimed: Set<UUID>, done: Set<UUID>, objects: [WorldObject]) -> [UUID]? {
        let standing = objects.filter { object in
            guard let phases = object.monster?.phases else { return false }
            return (object.monster?.phase ?? phases) < phases
        }
        let gone = claimed.subtracting(standing.map(\.id)).union(done)
        return gone.isEmpty ? nil : gone.sorted { $0.uuidString < $1.uuidString }
    }

    /// Every nth point, and always the last: a route can be thousands of points.
    static func sampled(_ path: [Coordinate], max: Int) -> [Coordinate] {
        guard path.count > max else { return path }
        let stride = Int((Double(path.count) / Double(max)).rounded(.up))
        var out = path.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
        if let last = path.last, out.last != last { out.append(last) }
        return out
    }

    static func distance(from point: Coordinate, to path: [Coordinate]) -> Double {
        var best = Double.infinity
        for i in 1..<path.count {
            best = min(best, GeoMath.distance(from: point, toSegment: path[i - 1], path[i]))
        }
        return best
    }

    /// The path's box, padded: anything outside it is too far to measure.
    static func bounds(of path: [Coordinate], padMeters: Double) -> BoundingBox {
        let lats = path.map(\.latitude)
        let lons = path.map(\.longitude)
        let minLat = lats.min() ?? 0, maxLat = lats.max() ?? 0
        let dLat = padMeters / 111_195
        let dLon = padMeters / (111_195 * Swift.max(0.2, cos(((minLat + maxLat) / 2) * .pi / 180)))
        return BoundingBox(minLat: minLat - dLat, minLon: (lons.min() ?? 0) - dLon, maxLat: maxLat + dLat, maxLon: (lons.max() ?? 0) + dLon)
    }
}

/// The fight on the Quest page: whose it is and how much health it has left, in
/// whole tenths. The Watch draws it as the creature's mark inside a ring of ten
/// ticks, with no numbers; a legend's (0.8.0) inside three arcs, one per phase.
public struct WatchFight: Codable, Hashable, Sendable {
    public var speciesId: String
    public var name: String
    /// The creature's mark as a `GameIcon` raw name; the Watch falls back to the species.
    public var icon: String?
    /// Whole tenths of its health left, 0…10, rounded up: a creature on its last
    /// scrap still shows one tick. A legend's: of the phase it is on.
    public var tenthsLeft: Int
    /// The creature this journey was planned for.
    public var quarry: Bool
    public var defeated: Bool
    /// A legend's health comes in phases (0.8.0): the one it is on, from 1, and how
    /// many it has. Nil for a creature, and from an older phone; an older Watch
    /// draws a legend as a creature with this phase's health.
    public var phase: Int?
    public var phases: Int?

    public init(speciesId: String, name: String, icon: String? = nil, tenthsLeft: Int, quarry: Bool, defeated: Bool,
                phase: Int? = nil, phases: Int? = nil) {
        self.speciesId = speciesId
        self.name = name
        self.icon = icon
        self.tenthsLeft = min(10, max(0, tenthsLeft))
        self.quarry = quarry
        self.defeated = defeated
        let count = phases.map { max(1, $0) }
        self.phases = count
        self.phase = count.map { count in min(count, max(1, phase ?? 1)) }
    }

    /// A legend: its health in phases.
    public var isLegend: Bool { phases != nil }

    /// The phases broken so far: those before the one it is on, and every one once it is defeated.
    public var phasesBroken: Int {
        guard let phases else { return 0 }
        return defeated ? phases : (phase ?? 1) - 1
    }

    /// Health left as whole tenths, rounded up (the phone's ring does the same).
    public static func tenths(_ fraction: Double) -> Int {
        let clamped = min(1, max(0, fraction))
        return clamped == 0 ? 0 : Int((clamped * 10).rounded(.up))
    }

    /// The fight worth showing: the quarry while it stands (from the health it
    /// started with until the journey reaches it); else the nearest foe being
    /// fought; else the quarry, defeated. Nil when nothing is being fought.
    ///
    /// A legend (0.8.0) is fought as a creature whose health is its phase's
    /// (`Legend.foe`), and drawn in its phases. Seen off on this journey means its
    /// phase broke: the next one stands whole (no more breaks today), and only the
    /// last phase broken is a defeat.
    public static func pick(
        objects: [WorldObject], quarryId: UUID?, from position: Coordinate?,
        isFought: (UUID) -> Bool, healthLeft: (UUID) -> Double?, isDefeated: (UUID) -> Bool,
        icon: (WorldObject) -> String? = { _ in nil }
    ) -> WatchFight? {
        let foes = objects.filter { $0.kind == .monster && isFought($0.id) }
        let quarry = quarryId.flatMap { id in foes.first { $0.id == id } }
        if let quarry, !isDefeated(quarry.id) {
            let fraction = healthLeft(quarry.id) ?? startingHealth(quarry) ?? 1
            return WatchFight(object: quarry, tenthsLeft: tenths(fraction), quarry: true, defeated: false, icon: icon(quarry))
        }
        let inPlay = foes.filter { $0.id != quarryId && !isDefeated($0.id) && healthLeft($0.id) != nil }
        var nearest = inPlay.first
        if let position {
            nearest = inPlay.min { GeoMath.distance(position, $0.coordinate) < GeoMath.distance(position, $1.coordinate) }
        }
        if let nearest {
            return WatchFight(object: nearest, tenthsLeft: tenths(healthLeft(nearest.id) ?? 1), quarry: false, defeated: false, icon: icon(nearest))
        }
        if let quarry {
            return WatchFight(seenOff: quarry, quarry: true, icon: icon(quarry))
        }
        return nil
    }

    init(object: WorldObject, tenthsLeft: Int, quarry: Bool, defeated: Bool, icon: String?) {
        self.init(speciesId: object.monster?.speciesId ?? "", name: object.name, icon: icon, tenthsLeft: tenthsLeft,
                  quarry: quarry, defeated: defeated, phase: object.monster?.phase, phases: object.monster?.phases)
    }

    /// Seen off on this journey: a creature defeated; a legend with its phase
    /// broken, the next standing whole, or defeated when that was its last.
    init(seenOff object: WorldObject, quarry: Bool, icon: String?) {
        guard let phases = object.monster?.phases else {
            self.init(object: object, tenthsLeft: 0, quarry: quarry, defeated: true, icon: icon)
            return
        }
        let broke = object.monster?.phase ?? phases
        let last = broke >= phases
        self.init(speciesId: object.monster?.speciesId ?? "", name: object.name, icon: icon, tenthsLeft: last ? 0 : 10,
                  quarry: quarry, defeated: last, phase: last ? phases : broke + 1, phases: phases)
    }

    /// The health a creature started this journey with, as the server sent it.
    static func startingHealth(_ object: WorldObject) -> Double? {
        guard let max = object.monster?.holdMax, max > 0 else { return nil }
        return Double(object.monster?.holdLeft ?? max) / Double(max)
    }
}

public extension EncounterTracker {
    /// The fight for the Watch, as `FightTracker` has folded it so far. Nil when the
    /// phone is not following fights on this journey. A legend among the objects
    /// (`Legend.foe`, 0.8.0) is a foe like any creature, drawn in its phases.
    func watchFight(quarryId: UUID?, from position: Coordinate?, icon: (WorldObject) -> String? = { _ in nil }) -> WatchFight? {
        guard let fights else { return nil }
        let claimed = claimedIDs
        return WatchFight.pick(
            objects: objects, quarryId: quarryId, from: position,
            isFought: { fights.fights($0) }, healthLeft: { fights.holdFraction(of: $0) },
            isDefeated: { claimed.contains($0) || fights.seenOff.contains($0) }, icon: icon
        )
    }
}

/// One thing found on the journey, as a line of Journey's end on the wrist.
public struct WatchFind: Codable, Hashable, Sendable {
    /// The line itself: "Tin Bell", "New rune: Raido", "The Crown".
    public var name: String
    /// Its mark as a `GameIcon` raw name; the Watch falls back to a plain token.
    public var icon: String?
    /// For an item: COMMON, RARE or LEGENDARY.
    public var rarity: String?

    public init(name: String, icon: String? = nil, rarity: String? = nil) {
        self.name = name
        self.icon = icon
        self.rarity = rarity
    }
}

/// iPhone → Watch, once the server has counted the journey: Journey's end on the
/// wrist. Sent after Save on the phone or End on the Watch. Watch builds before
/// 0.7.2 drop it (an unknown kind is ignored).
public struct WatchJourneyEnd: Codable, Hashable, Sendable {
    /// RIDE, RUN or WALK.
    public var activity: String?
    public var creaturesDefeated: Int
    public var chestsOpened: Int
    public var coins: Int
    public var xp: Int
    /// The level reached, when the journey brought a level up.
    public var levelReached: Int?
    public var finds: [WatchFind]
    /// When the journey ended, so a Watch that hears of it much later can let it go.
    public var endedAt: Date?
    /// 0.8.0, each nil when there is nothing to say and from an older phone (an
    /// older Watch ignores them): the legend's line ("Phase broken! The Fog Dragon
    /// is down to its last phase."), the lair's, and the buried treasure dug up.
    public var legend: WatchEndLine?
    public var lair: WatchEndLine?
    public var treasureFound: WatchEndLine?
    /// 0.9.0, nil when there are none and from an older phone (an older Watch
    /// ignores them): the districts this journey made yours, by name ("Yours:
    /// Rotherhithe, Bermondsey"), and those it completed ("District complete!").
    public var districts: [String]?
    public var completedDistricts: [String]?

    public init(activity: String? = nil, creaturesDefeated: Int = 0, chestsOpened: Int = 0, coins: Int = 0, xp: Int = 0,
                levelReached: Int? = nil, finds: [WatchFind] = [], endedAt: Date? = nil,
                legend: WatchEndLine? = nil, lair: WatchEndLine? = nil, treasureFound: WatchEndLine? = nil,
                districts: [String]? = nil, completedDistricts: [String]? = nil) {
        self.districts = districts
        self.completedDistricts = completedDistricts
        self.activity = activity
        self.creaturesDefeated = creaturesDefeated
        self.chestsOpened = chestsOpened
        self.coins = coins
        self.xp = xp
        self.levelReached = levelReached
        self.finds = finds
        self.endedAt = endedAt
        self.legend = legend
        self.lair = lair
        self.treasureFound = treasureFound
    }

    /// Journey's end from the processed summary: creatures defeated and chests
    /// opened, coins and XP, the level reached, and what was found (items, rune
    /// stones, then new places). `placeIcon` names a place's `GameIcon` from its
    /// category: the phone knows the art, Core does not.
    public init(summary: AdventureSummary, placeIcon: (DiscoveryCategory) -> String? = { _ in nil }) {
        let claimed = summary.worldObjects?.claimed ?? []
        var finds: [WatchFind] = []
        // Items first: a sold one still shows, so the rider knows what the full bag cost them.
        for item in summary.itemsFound ?? [] {
            finds.append(WatchFind(name: item.soldOnTheSpot ? "\(item.name) (sold)" : item.name, icon: item.icon, rarity: item.rarity))
        }
        for found in summary.runesFound ?? [] {
            let rune = found.rune.capitalized
            finds.append(WatchFind(name: found.new ? "New rune: \(rune)" : "\(rune) rune stone", icon: "runeStone"))
        }
        for place in summary.discoveries {
            finds.append(WatchFind(name: place.name, icon: placeIcon(place.category)))
        }
        // 0.8.0: the legend, the lair and buried treasure, each when there is something to say.
        let legend = summary.legend.flatMap {
            WatchEndLine.legend(name: $0.name, icon: $0.icon, line: $0.line, damage: $0.damage, phaseBroken: $0.phaseBroken, defeated: $0.defeated)
        }
        let lair = summary.lair.map { WatchEndLine.lair(name: $0.name, visited: $0.visited, need: $0.need, done: $0.done) }
        let treasures = summary.treasures
        let treasure = treasures.isEmpty ? nil : WatchEndLine.treasure(count: treasures.count, coins: treasures.compactMap(\.coins).reduce(0, +))
        self.init(
            activity: summary.ride.activity.flatMap { $0 == .unknown ? nil : $0.rawValue },
            creaturesDefeated: claimed.filter { $0.kind == .monster }.count,
            chestsOpened: claimed.filter { $0.kind == .chest }.count,
            coins: summary.acAwarded ?? 0,
            xp: summary.xpAwarded,
            levelReached: summary.levelUps.filter { $0.kind == .overall }.map(\.to).max(),
            finds: finds,
            endedAt: summary.ride.endedAt,
            legend: legend,
            lair: lair,
            treasureFound: treasure,
            // 0.9.0: "Yours: Rotherhithe, Bermondsey" and "District complete!".
            districts: Self.districtNames(summary.districtsMadeYours),
            completedDistricts: Self.districtNames(summary.districtsCompleted)
        )
    }
}
