import Foundation

// Legends (0.8.0, "The old ones"): a great creature that takes several journeys.
// Its health comes in three phases, each weak to its own kinds of effort; at most
// one phase breaks a journey and a day. Every type here is new with 0.8.0 and
// reads leniently: a field the server leaves out never stops the World opening.

/// AWAKE, DORMANT or DEFEATED, as the server spells it. A string on the wire.
public enum LegendStatus {
    public static let awake = "AWAKE"
    public static let dormant = "DORMANT"
    public static let defeated = "DEFEATED"
}

/// One phase of a legend's health (`LegendOut.phases[]`).
public struct LegendPhase: Codable, Hashable, Sendable, Identifiable {
    /// 1, 2 or 3.
    public var n: Int
    /// Kinds of effort it is weak to and resists: ROAD, GROUND, CLIMB, RUNE, WORD.
    public var weakTo: [String]
    public var resists: [String]
    public var healthMax: Int
    public var healthLeft: Int
    public var broken: Bool
    /// What rune lands on it in this phase: ANY (any rune shape, or a woken rune),
    /// WOKEN (only a rune woken on a rune ride) or a rune's id, whose shape is `roadForm`.
    public var rune: String?
    public var roadForm: String?
    /// A stop of a few minutes beside it counts as a note (the Water Wyrm's second phase).
    public var stopIsNote: Bool = false

    public var id: Int { n }
    /// 0…1 of this phase's health left.
    public var fraction: Double { healthMax > 0 ? min(1, max(0, Double(healthLeft) / Double(healthMax))) : 0 }

    public init(n: Int, weakTo: [String], resists: [String] = [], healthMax: Int, healthLeft: Int, broken: Bool = false,
                rune: String? = nil, roadForm: String? = nil) {
        self.n = n
        self.weakTo = weakTo
        self.resists = resists
        self.healthMax = healthMax
        self.healthLeft = healthLeft
        self.broken = broken
        self.rune = rune
        self.roadForm = roadForm
    }

    private enum CodingKeys: String, CodingKey { case n, weakTo, resists, healthMax, healthLeft, broken, rune, roadForm, stopIsNote }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 1
        weakTo = (try? c.decodeIfPresent([String].self, forKey: .weakTo)) ?? []
        resists = (try? c.decodeIfPresent([String].self, forKey: .resists)) ?? []
        healthMax = (try? c.decodeIfPresent(Int.self, forKey: .healthMax)) ?? Legend.phaseHealth
        healthLeft = (try? c.decodeIfPresent(Int.self, forKey: .healthLeft)) ?? healthMax
        broken = (try? c.decodeIfPresent(Bool.self, forKey: .broken)) ?? (healthLeft <= 0)
        rune = (try? c.decodeIfPresent(String.self, forKey: .rune)) ?? nil
        roadForm = (try? c.decodeIfPresent(String.self, forKey: .roadForm)) ?? nil
        stopIsNote = (try? c.decodeIfPresent(Bool.self, forKey: .stopIsNote)) ?? false
    }

    /// Any rune shape cut near it lands, or a woken rune.
    public static let anyRune = "ANY"
    /// Only a rune woken on a rune ride lands.
    public static let wokenRune = "WOKEN"
}

/// A journey that hurt it (`LegendOut.journeys[]`, on `GET /legends/{id}`).
public struct LegendJourney: Codable, Hashable, Sendable {
    public var rideId: String?
    public var date: Date?
    public var damage: Int
    public var phase: Int

    public init(rideId: String? = nil, date: Date? = nil, damage: Int, phase: Int) {
        self.rideId = rideId
        self.date = date
        self.damage = damage
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey { case rideId, date, damage, phase }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rideId = (try? c.decodeIfPresent(String.self, forKey: .rideId)) ?? nil
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? nil
        damage = (try? c.decodeIfPresent(Int.self, forKey: .damage)) ?? 0
        phase = (try? c.decodeIfPresent(Int.self, forKey: .phase)) ?? 1
    }
}

/// A legend (`LegendOut`): where it lives, its three phases, what it leaves.
public struct Legend: Codable, Hashable, Sendable, Identifiable {
    /// Each phase's health when the config does not say (1,500 in three).
    public static let phaseHealth = 500
    public static let phaseCount = 3

    public var id: UUID
    public var speciesId: String
    public var name: String
    /// The `GameIcon` raw name to draw it with ("fogDragon").
    public var icon: String?
    /// One sentence.
    public var flavour: String?
    /// Its page: a couple of sentences.
    public var page: String?
    public var latitude: Double
    public var longitude: Double
    public var anchorName: String?
    /// AWAKE, DORMANT or DEFEATED.
    public var status: String
    /// The phase it is in: 1, 2 or 3.
    public var phase: Int
    public var phases: [LegendPhase]
    public var healthLeft: Int
    public var healthMax: Int
    /// Its one free move has been used.
    public var moved: Bool
    public var wokeAt: Date?
    public var lastHitAt: Date?
    /// Health it gets back a week left alone (50), and the days untouched before it sleeps (28).
    public var healsPerWeek: Int?
    public var sleepsAfterDays: Int?
    /// The Hard rune it leaves when it is defeated ("hagalaz").
    public var rune: String?
    /// The journeys that hurt it, on `GET /legends/{id}` only.
    public var journeys: [LegendJourney]?
    /// Where this kind lives, in words: "water with a path beside it".
    public var livesAt: String?
    /// When it falls asleep if left alone.
    public var sleepsAt: Date?
    /// A phase broke today, so the next cannot until tomorrow.
    public var phaseBrokenToday: Bool = false
    /// 1 the first time round, 2 for "the Fog Dragon II".
    public var round: Int = 1

    public init(id: UUID, speciesId: String, name: String, icon: String? = nil, flavour: String? = nil, page: String? = nil,
                latitude: Double, longitude: Double, anchorName: String? = nil, status: String = LegendStatus.awake,
                phase: Int = 1, phases: [LegendPhase] = [], healthLeft: Int? = nil, healthMax: Int? = nil, moved: Bool = false,
                wokeAt: Date? = nil, lastHitAt: Date? = nil, healsPerWeek: Int? = nil, sleepsAfterDays: Int? = nil,
                rune: String? = nil, journeys: [LegendJourney]? = nil) {
        self.id = id
        self.speciesId = speciesId
        self.name = name
        self.icon = icon
        self.flavour = flavour
        self.page = page
        self.latitude = latitude
        self.longitude = longitude
        self.anchorName = anchorName
        self.status = status
        self.phase = phase
        self.phases = phases
        self.healthLeft = healthLeft ?? phases.reduce(0) { $0 + $1.healthLeft }
        self.healthMax = healthMax ?? phases.reduce(0) { $0 + $1.healthMax }
        self.moved = moved
        self.wokeAt = wokeAt
        self.lastHitAt = lastHitAt
        self.healsPerWeek = healsPerWeek
        self.sleepsAfterDays = sleepsAfterDays
        self.rune = rune
        self.journeys = journeys
    }

    private enum CodingKeys: String, CodingKey {
        case id, speciesId, name, icon, flavour, page, latitude, longitude, anchorName, status, phase, phases, healthLeft, healthMax
        case moved, wokeAt, lastHitAt, healsPerWeek, sleepsAfterDays, rune, journeys, livesAt, sleepsAt, phaseBrokenToday, round
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        speciesId = (try? c.decodeIfPresent(String.self, forKey: .speciesId)) ?? ""
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        flavour = (try? c.decodeIfPresent(String.self, forKey: .flavour)) ?? nil
        page = (try? c.decodeIfPresent(String.self, forKey: .page)) ?? nil
        anchorName = (try? c.decodeIfPresent(String.self, forKey: .anchorName)) ?? nil
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? LegendStatus.awake
        phase = (try? c.decodeIfPresent(Int.self, forKey: .phase)) ?? 1
        phases = (try? c.decodeIfPresent([LegendPhase].self, forKey: .phases)) ?? []
        healthLeft = (try? c.decodeIfPresent(Int.self, forKey: .healthLeft)) ?? phases.reduce(0) { $0 + $1.healthLeft }
        healthMax = (try? c.decodeIfPresent(Int.self, forKey: .healthMax)) ?? phases.reduce(0) { $0 + $1.healthMax }
        moved = (try? c.decodeIfPresent(Bool.self, forKey: .moved)) ?? false
        wokeAt = (try? c.decodeIfPresent(Date.self, forKey: .wokeAt)) ?? nil
        lastHitAt = (try? c.decodeIfPresent(Date.self, forKey: .lastHitAt)) ?? nil
        healsPerWeek = (try? c.decodeIfPresent(Int.self, forKey: .healsPerWeek)) ?? nil
        sleepsAfterDays = (try? c.decodeIfPresent(Int.self, forKey: .sleepsAfterDays)) ?? nil
        rune = (try? c.decodeIfPresent(String.self, forKey: .rune)) ?? nil
        journeys = (try? c.decodeIfPresent([LegendJourney].self, forKey: .journeys)) ?? nil
        livesAt = (try? c.decodeIfPresent(String.self, forKey: .livesAt)) ?? nil
        sleepsAt = (try? c.decodeIfPresent(Date.self, forKey: .sleepsAt)) ?? nil
        phaseBrokenToday = (try? c.decodeIfPresent(Bool.self, forKey: .phaseBrokenToday)) ?? false
        round = (try? c.decodeIfPresent(Int.self, forKey: .round)) ?? 1
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    public var isAwake: Bool { status == LegendStatus.awake }
    public var isDefeated: Bool { status == LegendStatus.defeated }
    /// The phase being fought now; the first unbroken one if the server's number is off.
    public var currentPhase: LegendPhase? {
        phases.first { $0.n == phase && !$0.broken } ?? phases.sorted { $0.n < $1.n }.first { !$0.broken }
    }
    /// "Phase 2 of 3".
    public var phaseLine: String { "Phase \(min(phase, max(phases.count, Self.phaseCount))) of \(max(phases.count, Self.phaseCount))" }

    /// The legend as a journey fights it (0.8.0): a creature whose health is this
    /// phase's, weak to and resisting what this phase is, with the phase marked on
    /// it so the ride, the ring and the Watch can tell it from a creature. nil once
    /// it is asleep or down.
    public var foe: WorldObject? {
        guard isAwake, let current = currentPhase, current.healthLeft > 0 else { return nil }
        var info = MonsterInfo(
            hp: current.healthMax, flavour: flavour, speciesId: speciesId,
            sigil: CreatureSigil(body: "legend", feature: speciesId, mark: "", icon: icon),
            holdMax: current.healthMax, holdLeft: current.healthLeft, wants: current.weakTo, minds: current.resists,
            rune: current.rune, roadForm: current.roadForm, displayName: name, phase: current.n,
            phases: max(phases.count, Self.phaseCount)
        )
        if phaseBrokenToday { info.phaseHeld = true }
        return WorldObject(id: id, kind: .monster, status: .spawned, tier: Self.foeTier, latitude: latitude, longitude: longitude,
                           name: name, anchorName: anchorName, rewardAC: 0, expiresAt: Date.distantFuture, monster: info)
    }

    /// The tier a legend fights at: above any creature's, so what works "against
    /// elders" works against it too.
    public static let foeTier = 4

    /// Where its journeys hurt this phase, as the share of the phase's health each
    /// had taken by then, in order: the notches on the phase's bar.
    public func notches(phase n: Int) -> [Double] {
        guard let max = phases.first(where: { $0.n == n })?.healthMax, max > 0 else { return [] }
        var taken = 0
        return (journeys ?? []).filter { $0.phase == n && $0.damage > 0 }.map { journey in
            taken += journey.damage
            return min(1, Double(taken) / Double(max))
        }
    }
}

/// A legend seen off or met before, for the Codex (`GET /legends`, `defeated[]`).
public struct LegendSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var speciesId: String?
    public var name: String
    public var icon: String?
    public var flavour: String?
    public var page: String?
    public var status: String?
    public var rune: String?
    public var defeatedAt: Date?
    public var wokeAt: Date?

    public init(id: UUID, speciesId: String? = nil, name: String, icon: String? = nil, flavour: String? = nil, page: String? = nil,
                status: String? = LegendStatus.defeated, rune: String? = nil, defeatedAt: Date? = nil) {
        self.id = id
        self.speciesId = speciesId
        self.name = name
        self.icon = icon
        self.flavour = flavour
        self.page = page
        self.status = status
        self.rune = rune
        self.defeatedAt = defeatedAt
    }

    private enum CodingKeys: String, CodingKey { case id, speciesId, name, icon, flavour, page, status, rune, defeatedAt, wokeAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        speciesId = (try? c.decodeIfPresent(String.self, forKey: .speciesId)) ?? nil
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        flavour = (try? c.decodeIfPresent(String.self, forKey: .flavour)) ?? nil
        page = (try? c.decodeIfPresent(String.self, forKey: .page)) ?? nil
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        rune = (try? c.decodeIfPresent(String.self, forKey: .rune)) ?? nil
        defeatedAt = (try? c.decodeIfPresent(Date.self, forKey: .defeatedAt)) ?? nil
        wokeAt = (try? c.decodeIfPresent(Date.self, forKey: .wokeAt)) ?? nil
    }

    public init(_ legend: Legend) {
        self.init(id: legend.id, speciesId: legend.speciesId, name: legend.name, icon: legend.icon, flavour: legend.flavour,
                  page: legend.page, status: legend.status, rune: legend.rune)
    }
}

/// `GET /legends`: the one awake (if any), those defeated, and how many more
/// creatures to defeat before the next wakes.
public struct LegendsState: Codable, Hashable, Sendable {
    public var awake: Legend?
    public var defeated: [LegendSummary]
    /// Met, left alone four weeks, and asleep until they wake again.
    public var sleeping: [LegendSummary]
    public var creaturesUntilNext: Int?

    public init(awake: Legend? = nil, defeated: [LegendSummary] = [], sleeping: [LegendSummary] = [], creaturesUntilNext: Int? = nil) {
        self.awake = awake
        self.defeated = defeated
        self.sleeping = sleeping
        self.creaturesUntilNext = creaturesUntilNext
    }

    private enum CodingKeys: String, CodingKey { case awake, defeated, sleeping, creaturesUntilNext }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        awake = (try? c.decodeIfPresent(Legend.self, forKey: .awake)) ?? nil
        defeated = (try? c.decodeIfPresent([LegendSummary].self, forKey: .defeated)) ?? []
        sleeping = (try? c.decodeIfPresent([LegendSummary].self, forKey: .sleeping)) ?? []
        creaturesUntilNext = (try? c.decodeIfPresent(Int.self, forKey: .creaturesUntilNext)) ?? nil
    }

    /// Every legend met: the one awake, those asleep, those defeated.
    public var met: [LegendSummary] { (awake.map { [LegendSummary($0)] } ?? []) + sleeping + defeated }
}

/// A Hard rune paid by a legend or a lair: its id, read from a bare id or from
/// the rune stone the server records (`{"rune": "hagalaz", "name": "Hagalaz", …}`).
public struct RunePaid: Codable, Hashable, Sendable {
    public var rune: String
    public var name: String?

    public init(rune: String, name: String? = nil) {
        self.rune = rune
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case rune, id, name }

    public init(from decoder: Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(String.self) {
            self.init(rune: id)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = ((try? c.decodeIfPresent(String.self, forKey: .rune)) ?? nil) ?? ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil)
        guard let id else { throw DecodingError.dataCorruptedError(forKey: .rune, in: c, debugDescription: "No rune id") }
        self.init(rune: id, name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rune, forKey: .rune)
        try c.encodeIfPresent(name, forKey: .name)
    }
}

/// A title, read from a bare name or from `{"name": …}` / `{"title": …}`.
struct LenientTitle: Decodable {
    var name: String?

    private enum CodingKeys: String, CodingKey { case name, title }

    init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            name = plain
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil)
    }
}

/// A legend that woke at the end of this journey (`summary.legendWoke`).
public struct LegendWoke: Codable, Hashable, Sendable {
    public var id: UUID?
    public var speciesId: String?
    public var name: String
    public var icon: String?
    /// "A legend has woken: the Fog Dragon".
    public var line: String?

    public init(id: UUID? = nil, speciesId: String? = nil, name: String, icon: String? = nil, line: String? = nil) {
        self.id = id
        self.speciesId = speciesId
        self.name = name
        self.icon = icon
        self.line = line
    }
}

/// What a phase break or a defeat paid (`summary.legend.rewards`): coins, XP,
/// the items (a Rare or Legendary one and a treasure map), and on its defeat its
/// Hard rune and a title.
public struct LegendRewards: Codable, Hashable, Sendable {
    public var coins: Int?
    public var xp: Int?
    public var items: [ItemFound]?
    public var rune: RunePaid?
    /// "Bane of the Fog Dragon", on its defeat.
    public var title: String?

    public init(coins: Int? = nil, xp: Int? = nil, items: [ItemFound]? = nil, rune: RunePaid? = nil, title: String? = nil) {
        self.coins = coins
        self.xp = xp
        self.items = items
        self.rune = rune
        self.title = title
    }

    private enum CodingKeys: String, CodingKey { case coins, xp, items, item, rune, title }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coins = (try? c.decodeIfPresent(Int.self, forKey: .coins)) ?? nil
        xp = (try? c.decodeIfPresent(Int.self, forKey: .xp)) ?? nil
        let one = (try? c.decodeIfPresent(ItemFound.self, forKey: .item)) ?? nil
        let many = (try? c.decodeIfPresent([ItemFound].self, forKey: .items)) ?? nil
        items = (many ?? []) + (one.map { [$0] } ?? [])
        if items?.isEmpty == true, many == nil { items = nil }
        rune = (try? c.decodeIfPresent(RunePaid.self, forKey: .rune)) ?? nil
        title = ((try? c.decodeIfPresent(LenientTitle.self, forKey: .title)) ?? nil)?.name
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(coins, forKey: .coins)
        try c.encodeIfPresent(xp, forKey: .xp)
        try c.encodeIfPresent(items, forKey: .items)
        try c.encodeIfPresent(rune, forKey: .rune)
        try c.encodeIfPresent(title, forKey: .title)
    }
}

/// What a journey did to the legend (`summary.legend`). `healthLeft`/`healthMax`
/// are over all three phases; `phaseHealthLeft`/`phaseHealthMax` the phase it is in now.
public struct LegendOutcome: Codable, Hashable, Sendable {
    public var id: UUID?
    public var speciesId: String?
    public var name: String
    public var icon: String?
    public var phaseBefore: Int
    public var phaseAfter: Int
    public var healthLeft: Int
    public var healthMax: Int
    public var phaseHealthLeft: Int?
    public var phaseHealthMax: Int?
    public var damage: Int
    /// Damage by kind of effort: {"GROUND": 120, …}.
    public var kinds: [String: Int]
    public var phaseBroken: Bool
    public var defeated: Bool
    /// Enough to break a phase, on a day one had already broken: it waits with 1 left.
    public var heldOver: Bool
    public var rewards: LegendRewards?
    /// "Phase broken! The Fog Dragon is down to its last phase."
    public var line: String?

    public init(id: UUID? = nil, speciesId: String? = nil, name: String, icon: String? = nil, phaseBefore: Int, phaseAfter: Int,
                healthLeft: Int, healthMax: Int, phaseHealthLeft: Int? = nil, phaseHealthMax: Int? = nil, damage: Int,
                kinds: [String: Int] = [:], phaseBroken: Bool = false, defeated: Bool = false, heldOver: Bool = false,
                rewards: LegendRewards? = nil, line: String? = nil) {
        self.id = id
        self.speciesId = speciesId
        self.name = name
        self.icon = icon
        self.phaseBefore = phaseBefore
        self.phaseAfter = phaseAfter
        self.healthLeft = healthLeft
        self.healthMax = healthMax
        self.phaseHealthLeft = phaseHealthLeft
        self.phaseHealthMax = phaseHealthMax
        self.damage = damage
        self.kinds = kinds
        self.phaseBroken = phaseBroken
        self.defeated = defeated
        self.heldOver = heldOver
        self.rewards = rewards
        self.line = line
    }

    private enum CodingKeys: String, CodingKey {
        case id, speciesId, name, icon, phaseBefore, phaseAfter, healthLeft, healthMax, phaseHealthLeft, phaseHealthMax, damage, kinds
        case phaseBroken, defeated, heldOver, rewards, line
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil
        speciesId = (try? c.decodeIfPresent(String.self, forKey: .speciesId)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "The legend"
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil
        phaseBefore = (try? c.decodeIfPresent(Int.self, forKey: .phaseBefore)) ?? 1
        phaseAfter = (try? c.decodeIfPresent(Int.self, forKey: .phaseAfter)) ?? phaseBefore
        healthMax = (try? c.decodeIfPresent(Int.self, forKey: .healthMax)) ?? Legend.phaseHealth * Legend.phaseCount
        healthLeft = (try? c.decodeIfPresent(Int.self, forKey: .healthLeft)) ?? healthMax
        phaseHealthLeft = (try? c.decodeIfPresent(Int.self, forKey: .phaseHealthLeft)) ?? nil
        phaseHealthMax = (try? c.decodeIfPresent(Int.self, forKey: .phaseHealthMax)) ?? nil
        damage = (try? c.decodeIfPresent(Int.self, forKey: .damage)) ?? 0
        kinds = (try? c.decodeIfPresent([String: Int].self, forKey: .kinds)) ?? [:]
        phaseBroken = (try? c.decodeIfPresent(Bool.self, forKey: .phaseBroken)) ?? false
        defeated = (try? c.decodeIfPresent(Bool.self, forKey: .defeated)) ?? false
        heldOver = (try? c.decodeIfPresent(Bool.self, forKey: .heldOver)) ?? false
        rewards = (try? c.decodeIfPresent(LegendRewards.self, forKey: .rewards)) ?? nil
        line = (try? c.decodeIfPresent(String.self, forKey: .line)) ?? nil
    }

    /// The phase it is in now: what is left of it and its most (the whole, from a server that sends no phase numbers).
    public var phaseLeft: Int { phaseHealthLeft ?? healthLeft }
    public var phaseMax: Int { phaseHealthMax ?? healthMax }
    /// 0…1 of the phase it is in now, for the bar on Journey's end.
    public var fraction: Double { phaseMax > 0 ? min(1, max(0, Double(phaseLeft) / Double(phaseMax))) : 0 }
}

// MARK: - Lairs (0.8.0)

/// A lair (`WorldObjectOut.lair`): its seven tiles by their middles, the ones
/// visited (by index), how many it needs, and when it ends.
public struct LairInfo: Codable, Hashable, Sendable {
    /// [[latitude, longitude], …]: its own tile first, then the six round it.
    public var cells: [[Double]]
    public var visited: [Int]
    public var need: Int
    public var endsAt: Date?

    public init(cells: [[Double]], visited: [Int] = [], need: Int = 5, endsAt: Date? = nil) {
        self.cells = cells
        self.visited = visited
        self.need = need
        self.endsAt = endsAt
    }

    private enum CodingKeys: String, CodingKey { case cells, visited, need, endsAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cells = (try? c.decodeIfPresent([[Double]].self, forKey: .cells)) ?? []
        visited = (try? c.decodeIfPresent([Int].self, forKey: .visited)) ?? []
        need = (try? c.decodeIfPresent(Int.self, forKey: .need)) ?? 5
        endsAt = (try? c.decodeIfPresent(Date.self, forKey: .endsAt)) ?? nil
    }

    /// The tiles' middles, in order.
    public var centres: [Coordinate] { cells.compactMap { $0.count >= 2 ? Coordinate(latitude: $0[0], longitude: $0[1]) : nil } }
    /// How many different tiles have been visited.
    public var visitedCount: Int { Set(visited.filter { $0 >= 0 && $0 < cells.count }).count }
    public var done: Bool { visitedCount >= need }

    /// Each tile's outline from the H3 cell at its middle, and whether it was visited.
    public func tiles(indexing: any CellIndexing, resolution: Int) -> [LairTile] {
        let seen = Set(visited)
        return centres.enumerated().map { index, centre in
            let cell = indexing.cell(at: centre, resolution: resolution)
            return LairTile(index: index, cell: cell, outline: indexing.boundary(of: cell), visited: seen.contains(index))
        }
    }
}

/// One of a lair's seven tiles, ready to draw.
public struct LairTile: Hashable, Sendable, Identifiable {
    public var index: Int
    public var cell: String
    public var outline: [Coordinate]
    public var visited: Bool

    public var id: String { cell }

    public init(index: Int, cell: String, outline: [Coordinate], visited: Bool) {
        self.index = index
        self.cell = cell
        self.outline = outline
        self.visited = visited
    }
}

/// What a journey did for the lair (`summary.lair`): tiles visited of those it
/// needs, and the great chest once it is done.
public struct LairOutcome: Codable, Hashable, Sendable {
    public var name: String
    public var visited: Int
    public var need: Int
    public var done: Bool
    public var rewards: LairRewards?
    /// Its tiles, and how many this journey visited for the first time.
    public var tiles: Int?
    public var newTiles: Int?
    /// "4 / 5 of the lair's tiles visited."
    public var line: String?

    public init(name: String, visited: Int, need: Int = 5, done: Bool = false, rewards: LairRewards? = nil) {
        self.name = name
        self.visited = visited
        self.need = need
        self.done = done
        self.rewards = rewards
    }

    private enum CodingKeys: String, CodingKey { case name, visited, need, done, rewards, tiles, newTiles, line }

    /// `visited` may be a count or the tiles' indices.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "The lair"
        if let count = try? c.decodeIfPresent(Int.self, forKey: .visited) {
            visited = count
        } else {
            visited = Set((try? c.decodeIfPresent([Int].self, forKey: .visited)) ?? []).count
        }
        need = (try? c.decodeIfPresent(Int.self, forKey: .need)) ?? 5
        done = (try? c.decodeIfPresent(Bool.self, forKey: .done)) ?? (visited >= need)
        rewards = (try? c.decodeIfPresent(LairRewards.self, forKey: .rewards)) ?? nil
        tiles = (try? c.decodeIfPresent(Int.self, forKey: .tiles)) ?? nil
        newTiles = (try? c.decodeIfPresent(Int.self, forKey: .newTiles)) ?? nil
        line = (try? c.decodeIfPresent(String.self, forKey: .line)) ?? nil
    }
}

/// A lair's great chest: coins, a Rare item, a sealed chest, and the first time a rune.
public struct LairRewards: Codable, Hashable, Sendable {
    public var coins: Int?
    public var item: ItemFound?
    public var items: [ItemFound]?
    public var rune: RunePaid?

    public init(coins: Int? = nil, item: ItemFound? = nil, items: [ItemFound]? = nil, rune: RunePaid? = nil) {
        self.coins = coins
        self.item = item
        self.items = items
        self.rune = rune
    }

    private enum CodingKeys: String, CodingKey { case coins, item, items, rune }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coins = (try? c.decodeIfPresent(Int.self, forKey: .coins)) ?? nil
        item = (try? c.decodeIfPresent(ItemFound.self, forKey: .item)) ?? nil
        items = (try? c.decodeIfPresent([ItemFound].self, forKey: .items)) ?? nil
        rune = (try? c.decodeIfPresent(RunePaid.self, forKey: .rune)) ?? nil
    }

    /// Every item, whichever way it came.
    public var allItems: [ItemFound] { (item.map { [$0] } ?? []) + (items ?? []) }
}

// MARK: - Treasure maps (0.8.0)

/// A treasure map's clue (`POST …/TREASURE_MAP/use`, `GET /inventory/treasure`):
/// what it says, never where. There is no marker, ever.
public struct TreasureClue: Codable, Hashable, Sendable, Identifiable {
    public var treasureId: UUID?
    /// "Buried by water, in a green place, about 2 km north-east of here."
    public var clue: String
    public var buriedAt: Date?

    public var id: String { treasureId?.uuidString ?? clue }

    public init(treasureId: UUID? = nil, clue: String, buriedAt: Date? = nil) {
        self.treasureId = treasureId
        self.clue = clue
        self.buriedAt = buriedAt
    }

    private enum CodingKeys: String, CodingKey { case treasureId, id, clue, buriedAt, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        treasureId = ((try? c.decodeIfPresent(UUID.self, forKey: .treasureId)) ?? nil) ?? ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil)
        clue = try c.decode(String.self, forKey: .clue)
        buriedAt = ((try? c.decodeIfPresent(Date.self, forKey: .buriedAt)) ?? nil) ?? ((try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(treasureId, forKey: .treasureId)
        try c.encode(clue, forKey: .clue)
        try c.encodeIfPresent(buriedAt, forKey: .buriedAt)
    }
}

/// `GET /inventory/treasure`: the clues still open (one at a time). Read from a
/// bare list, `{"clues": […]}` or a single clue.
public struct TreasureClues: Decodable, Hashable, Sendable {
    public var clues: [TreasureClue]

    public init(clues: [TreasureClue]) {
        self.clues = clues
    }

    private enum CodingKeys: String, CodingKey { case clues, open, treasure }

    public init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([TreasureClue].self) {
            clues = list
        } else if let c = try? decoder.container(keyedBy: CodingKeys.self),
                  let list = (try? c.decodeIfPresent([TreasureClue].self, forKey: .clues)) ?? (try? c.decodeIfPresent([TreasureClue].self, forKey: .open)) {
            clues = list
        } else if let c = try? decoder.container(keyedBy: CodingKeys.self), let one = try? c.decodeIfPresent(TreasureClue.self, forKey: .treasure) {
            clues = [one]
        } else if let one = try? TreasureClue(from: decoder) {
            clues = [one]
        } else {
            clues = []
        }
    }
}

/// Buried treasure a journey passed and opened (`summary.treasureFound`).
public struct TreasureFound: Codable, Hashable, Sendable {
    public var treasureId: UUID?
    public var coins: Int?
    public var item: ItemFound?
    public var clue: String?
    public var line: String?

    public init(treasureId: UUID? = nil, coins: Int? = nil, item: ItemFound? = nil, clue: String? = nil, line: String? = nil) {
        self.treasureId = treasureId
        self.coins = coins
        self.item = item
        self.clue = clue
        self.line = line
    }

    private enum CodingKeys: String, CodingKey { case treasureId, id, coins, item, clue, line }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        treasureId = ((try? c.decodeIfPresent(UUID.self, forKey: .treasureId)) ?? nil) ?? ((try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? nil)
        coins = (try? c.decodeIfPresent(Int.self, forKey: .coins)) ?? nil
        item = (try? c.decodeIfPresent(ItemFound.self, forKey: .item)) ?? nil
        clue = (try? c.decodeIfPresent(String.self, forKey: .clue)) ?? nil
        line = (try? c.decodeIfPresent(String.self, forKey: .line)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(treasureId, forKey: .treasureId)
        try c.encodeIfPresent(coins, forKey: .coins)
        try c.encodeIfPresent(item, forKey: .item)
        try c.encodeIfPresent(clue, forKey: .clue)
        try c.encodeIfPresent(line, forKey: .line)
    }
}

/// `summary.treasureFound` may be one find, a list, or `true`: read as a list.
public struct TreasureFinds: Codable, Hashable, Sendable {
    public var finds: [TreasureFound]

    public init(_ finds: [TreasureFound]) {
        self.finds = finds
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let list = try? single.decode([TreasureFound].self) {
            finds = list
        } else if let one = try? single.decode(TreasureFound.self) {
            finds = [one]
        } else if let found = try? single.decode(Bool.self), found {
            finds = [TreasureFound()]
        } else {
            finds = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        try single.encode(finds)
    }
}

public extension LegendPhase {
    /// What one unit of a kind of effort takes off this phase, for this build and
    /// way of going: a metre, a tile, a rune shape, a note. The legend page's numbers,
    /// worked out as the fold does (`legend_cfg`, `pct_against_legend`), at no discount.
    func perUnit(_ kind: String, sheet: CharacterSheet, constants: CombatConstants, activity: Activity) -> Double {
        let cfg = sheet.legendConstants(sheet.fightConstants(constants))
        let pct = sheet.pctAgainstLegend(madeGoodMeters: 0, onFoot: activity == .run || activity == .walk)
        let foe = FightResolver.Foe(latitude: 0, longitude: 0, holdMax: Double(healthMax), holdBefore: Double(healthLeft), wants: weakTo,
                                    minds: resists)
        return FightResolver.perUnit(kind, foe, activity: activity.rawValue, pct: pct, cfg: cfg)
    }
}
