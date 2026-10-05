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

    /// The world object's id, or the objective's.
    public var id: UUID
    /// MONSTER, CHEST, COLLECTABLE or OBJECTIVE; a string, so a kind added later
    /// reaches an older Watch as something it draws plainly rather than an error.
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
            id: object.id, kind: object.kind.rawValue, name: object.name, latitude: object.latitude, longitude: object.longitude,
            icon: icon, speciesId: object.monster?.speciesId, tier: object.tier, bounty: object.isBounty ? true : nil,
            quarry: quarry ? true : nil
        )
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public var isQuarry: Bool { quarry ?? false }
    public var isBounty: Bool { bounty ?? false }
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
    /// quarry first, then bounties, then the nearest, at most `limit` of them;
    /// then each objective's place. `icon` names each thing's `GameIcon`: the
    /// phone knows the art, Core does not.
    public static func select(
        objects: [WorldObject], route: [Coordinate], start: Coordinate?, objectives: [Objective] = [], quarryId: UUID? = nil,
        icon: (WorldObject) -> String? = { _ in nil }
    ) -> [WatchWorldMark] {
        let path = sampled(route, max: 400)
        let reach = path.count >= 2 ? routeReachMeters : startReachMeters
        let box = path.count >= 2 ? bounds(of: path, padMeters: reach) : nil
        var near: [(object: WorldObject, meters: Double)] = []
        for object in objects where object.status == .spawned && object.kind != .unknown {
            if object.id == quarryId {
                near.append((object, 0))
                continue
            }
            let meters: Double
            if path.count >= 2, let box {
                guard box.contains(object.coordinate) else { continue }
                meters = distance(from: object.coordinate, to: path)
            } else if let start {
                meters = GeoMath.distance(start, object.coordinate)
            } else {
                continue
            }
            if meters <= reach { near.append((object, meters)) }
        }
        near.sort { a, b in
            let aFirst = (a.object.id == quarryId, a.object.isBounty)
            let bFirst = (b.object.id == quarryId, b.object.isBounty)
            if aFirst.0 != bFirst.0 { return aFirst.0 }
            if aFirst.1 != bFirst.1 { return aFirst.1 }
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
/// ticks, with no numbers.
public struct WatchFight: Codable, Hashable, Sendable {
    public var speciesId: String
    public var name: String
    /// The creature's mark as a `GameIcon` raw name; the Watch falls back to the species.
    public var icon: String?
    /// Whole tenths of its health left, 0…10, rounded up: a creature on its last
    /// scrap still shows one tick.
    public var tenthsLeft: Int
    /// The creature this journey was planned for.
    public var quarry: Bool
    public var defeated: Bool

    public init(speciesId: String, name: String, icon: String? = nil, tenthsLeft: Int, quarry: Bool, defeated: Bool) {
        self.speciesId = speciesId
        self.name = name
        self.icon = icon
        self.tenthsLeft = min(10, max(0, tenthsLeft))
        self.quarry = quarry
        self.defeated = defeated
    }

    /// Health left as whole tenths, rounded up (the phone's ring does the same).
    public static func tenths(_ fraction: Double) -> Int {
        let clamped = min(1, max(0, fraction))
        return clamped == 0 ? 0 : Int((clamped * 10).rounded(.up))
    }

    /// The fight worth showing: the quarry while it stands (from the health it
    /// started with until the journey reaches it); else the nearest creature being
    /// fought; else the quarry, defeated. Nil when nothing is being fought.
    public static func pick(
        objects: [WorldObject], quarryId: UUID?, from position: Coordinate?,
        isFought: (UUID) -> Bool, healthLeft: (UUID) -> Double?, isDefeated: (UUID) -> Bool,
        icon: (WorldObject) -> String? = { _ in nil }
    ) -> WatchFight? {
        let creatures = objects.filter { $0.kind == .monster && isFought($0.id) }
        let quarry = quarryId.flatMap { id in creatures.first { $0.id == id } }
        if let quarry, !isDefeated(quarry.id) {
            let fraction = healthLeft(quarry.id) ?? startingHealth(quarry) ?? 1
            return WatchFight(object: quarry, tenthsLeft: tenths(fraction), quarry: true, defeated: false, icon: icon(quarry))
        }
        let inPlay = creatures.filter { $0.id != quarryId && !isDefeated($0.id) && healthLeft($0.id) != nil }
        var nearest = inPlay.first
        if let position {
            nearest = inPlay.min { GeoMath.distance(position, $0.coordinate) < GeoMath.distance(position, $1.coordinate) }
        }
        if let nearest {
            return WatchFight(object: nearest, tenthsLeft: tenths(healthLeft(nearest.id) ?? 1), quarry: false, defeated: false, icon: icon(nearest))
        }
        if let quarry {
            return WatchFight(object: quarry, tenthsLeft: 0, quarry: true, defeated: true, icon: icon(quarry))
        }
        return nil
    }

    init(object: WorldObject, tenthsLeft: Int, quarry: Bool, defeated: Bool, icon: String?) {
        self.init(speciesId: object.monster?.speciesId ?? "", name: object.name, icon: icon, tenthsLeft: tenthsLeft,
                  quarry: quarry, defeated: defeated)
    }

    /// The health a creature started this journey with, as the server sent it.
    static func startingHealth(_ object: WorldObject) -> Double? {
        guard let max = object.monster?.holdMax, max > 0 else { return nil }
        return Double(object.monster?.holdLeft ?? max) / Double(max)
    }
}

public extension EncounterTracker {
    /// The fight for the Watch, as `FightTracker` has folded it so far. Nil when the
    /// phone is not following fights on this journey.
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

    public init(activity: String? = nil, creaturesDefeated: Int = 0, chestsOpened: Int = 0, coins: Int = 0, xp: Int = 0,
                levelReached: Int? = nil, finds: [WatchFind] = [], endedAt: Date? = nil) {
        self.activity = activity
        self.creaturesDefeated = creaturesDefeated
        self.chestsOpened = chestsOpened
        self.coins = coins
        self.xp = xp
        self.levelReached = levelReached
        self.finds = finds
        self.endedAt = endedAt
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
        self.init(
            activity: summary.ride.activity.flatMap { $0 == .unknown ? nil : $0.rawValue },
            creaturesDefeated: claimed.filter { $0.kind == .monster }.count,
            chestsOpened: claimed.filter { $0.kind == .chest }.count,
            coins: summary.acAwarded ?? 0,
            xp: summary.xpAwarded,
            levelReached: summary.levelUps.filter { $0.kind == .overall }.map(\.to).max(),
            finds: finds,
            endedAt: summary.ride.endedAt
        )
    }
}
