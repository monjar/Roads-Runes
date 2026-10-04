import Foundation

/// The character as the fight sees it, frozen onto a ride when it starts
/// (backend `characters/sheet.py`). The phone never works out a build; it folds
/// the fight over the sheet the server froze.
public struct CharacterSheet: Codable, Hashable, Sendable {
    public var version: Int
    public var characterClass: String
    public var overallLevel: Int
    public var classLevel: Int
    /// Summed percentages per kind of effort: 0.3 is +30%.
    public var damagePct: [String: Double]
    public var runeThreshold: Double
    public var runeReachMeters: Double
    /// Knacks that depend on the thing or the outing (0.6.2). Optional: a version 1
    /// sheet has none.
    public var vsEldersPct: Double?
    public var lateRoadPct: Double?
    public var lateRoadAfterMeters: Double?
    public var wordOldPlacesPct: Double?

    /// The build against one thing on this outing, as the server works it out
    /// (`CharacterSheet.pct_against`). The phone does not know which places are old,
    /// so the Historian's knack is left out and the phone is early, never late.
    public func pct(againstElder elder: Bool, madeGoodMeters: Double, onFoot: Bool) -> [String: Double] {
        var pct = damagePct
        if elder, let bonus = vsEldersPct, bonus > 0 {
            for kind in FightResolver.kinds { pct[kind, default: 0] += bonus }
        }
        if let bonus = lateRoadPct, bonus > 0, madeGoodMeters > (lateRoadAfterMeters ?? 10_000) / (onFoot ? 2 : 1) {
            pct["ROAD", default: 0] += bonus
        }
        return pct
    }

    public init(version: Int = 1, characterClass: String = "EXPLORER", overallLevel: Int = 1, classLevel: Int = 1,
                damagePct: [String: Double] = [:], runeThreshold: Double = 0.22, runeReachMeters: Double = 1000) {
        self.version = version
        self.characterClass = characterClass
        self.overallLevel = overallLevel
        self.classLevel = classLevel
        self.damagePct = damagePct
        self.runeThreshold = runeThreshold
        self.runeReachMeters = runeReachMeters
    }

    public static let neutral = CharacterSheet()
}

/// The fight's numbers (`world_objects.json`, `combat`), sent on `GET /config` so
/// a change needs no release. The defaults are the server's at 0.6.1, for a
/// phone that starts offline.
public struct CombatConstants: Codable, Hashable, Sendable {
    public var engageMeters: Double = 150
    public var groundMeters: Double = 1000
    public var breakOffMeters: Double = 1300
    public var strideMeters: Double = 15
    public var maxJumpMeters: Double = 250
    public var maxAccuracyMeters: Double = 30
    public var climbBandMeters: Double = 3
    public var roadCellResolution: Int = 11
    public var roadCapMeters: Double = 4000
    public var holdByTier: [String: Double] = ["1": 100, "2": 220, "3": 400]
    public var rates: [String: Double] = ["ROAD": 0.01, "GROUND": 15, "CLIMB": 1.25, "RUNE": 100, "WORD": 60]
    public var footScale: [String: Double] = ["ROAD": 2, "GROUND": 2, "CLIMB": 1.25]
    public var wants: Double = 2
    public var minds: Double = 0.5
    public var sheetClamp: [Double] = [0.25, 3.0]
    public var carriedFraction: Double = 0.2
    public var carriedCap: Double = 0.3
    public var wordRadiusMeters: Double = 120
    public var wordMinChars: Int = 12
    public var runeReachMeters: Double = 1000
    public var minOutingMeters: Double = 500

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case engageMeters, groundMeters, breakOffMeters, strideMeters, maxJumpMeters, maxAccuracyMeters
        case climbBandMeters, roadCellResolution, roadCapMeters, holdByTier, rates, footScale, wants, minds
        case sheetClamp, carriedFraction, carriedCap, wordRadiusMeters, wordMinChars, runeReachMeters, minOutingMeters
    }

    /// Every field optional on the wire: a server that adds or drops one does not
    /// stop the phone from fighting.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CombatConstants()
        engageMeters = try c.decodeIfPresent(Double.self, forKey: .engageMeters) ?? d.engageMeters
        groundMeters = try c.decodeIfPresent(Double.self, forKey: .groundMeters) ?? d.groundMeters
        breakOffMeters = try c.decodeIfPresent(Double.self, forKey: .breakOffMeters) ?? d.breakOffMeters
        strideMeters = try c.decodeIfPresent(Double.self, forKey: .strideMeters) ?? d.strideMeters
        maxJumpMeters = try c.decodeIfPresent(Double.self, forKey: .maxJumpMeters) ?? d.maxJumpMeters
        maxAccuracyMeters = try c.decodeIfPresent(Double.self, forKey: .maxAccuracyMeters) ?? d.maxAccuracyMeters
        climbBandMeters = try c.decodeIfPresent(Double.self, forKey: .climbBandMeters) ?? d.climbBandMeters
        roadCellResolution = try c.decodeIfPresent(Int.self, forKey: .roadCellResolution) ?? d.roadCellResolution
        roadCapMeters = try c.decodeIfPresent(Double.self, forKey: .roadCapMeters) ?? d.roadCapMeters
        holdByTier = try c.decodeIfPresent([String: Double].self, forKey: .holdByTier) ?? d.holdByTier
        rates = try c.decodeIfPresent([String: Double].self, forKey: .rates) ?? d.rates
        footScale = try c.decodeIfPresent([String: Double].self, forKey: .footScale) ?? d.footScale
        wants = try c.decodeIfPresent(Double.self, forKey: .wants) ?? d.wants
        minds = try c.decodeIfPresent(Double.self, forKey: .minds) ?? d.minds
        sheetClamp = try c.decodeIfPresent([Double].self, forKey: .sheetClamp) ?? d.sheetClamp
        carriedFraction = try c.decodeIfPresent(Double.self, forKey: .carriedFraction) ?? d.carriedFraction
        carriedCap = try c.decodeIfPresent(Double.self, forKey: .carriedCap) ?? d.carriedCap
        wordRadiusMeters = try c.decodeIfPresent(Double.self, forKey: .wordRadiusMeters) ?? d.wordRadiusMeters
        wordMinChars = try c.decodeIfPresent(Int.self, forKey: .wordMinChars) ?? d.wordMinChars
        runeReachMeters = try c.decodeIfPresent(Double.self, forKey: .runeReachMeters) ?? d.runeReachMeters
        minOutingMeters = try c.decodeIfPresent(Double.self, forKey: .minOutingMeters) ?? d.minOutingMeters
    }
}

/// What the server decided one outing did to one thing (`worldObjects.fights[]`).
public struct FightReport: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String?
    public var speciesId: String?
    public var tier: Int
    public var bounty: Bool?
    /// SEEN_OFF, LOOSENED or UNTOUCHED.
    public var outcome: String
    public var holdMax: Int
    public var holdBefore: Int
    public var holdAfter: Int
    /// Hold taken, by kind (ROAD, GROUND, CLIMB, RUNE, WORD, CARRIED).
    public var damage: [String: Int]
    public var units: [String: Double]?
    public var finisher: String?
    public var runeLanded: Bool?
    public var wordLanded: Bool?
    public var wouldHaveDone: WouldHaveDone?
    public var expiresAt: Date?
    /// Where it stood, for the ink mark on the reckoning's map.
    public var latitude: Double?
    public var longitude: Double?

    public var seenOff: Bool { outcome == "SEEN_OFF" }
    public var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }
    public var taken: Int { holdBefore - holdAfter }

    public init(id: UUID, name: String? = nil, speciesId: String? = nil, tier: Int = 1, bounty: Bool? = nil, outcome: String,
                holdMax: Int, holdBefore: Int, holdAfter: Int, damage: [String: Int] = [:], units: [String: Double]? = nil,
                finisher: String? = nil, runeLanded: Bool? = nil, wordLanded: Bool? = nil,
                wouldHaveDone: WouldHaveDone? = nil, expiresAt: Date? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id
        self.name = name
        self.speciesId = speciesId
        self.tier = tier
        self.bounty = bounty
        self.outcome = outcome
        self.holdMax = holdMax
        self.holdBefore = holdBefore
        self.holdAfter = holdAfter
        self.damage = damage
        self.units = units
        self.finisher = finisher
        self.runeLanded = runeLanded
        self.wordLanded = wordLanded
        self.wouldHaveDone = wouldHaveDone
        self.expiresAt = expiresAt
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The cheapest effort it wanted that would have finished it: "13 m of height".
public struct WouldHaveDone: Codable, Hashable, Sendable {
    public var kind: String
    public var units: Double
    public var unit: String

    public init(kind: String, units: Double, unit: String) {
        self.kind = kind
        self.units = units
        self.unit = unit
    }
}

/// A creature met for the first time on an outing (`codexFirsts`), for the codex stamp.
public struct CodexFirst: Codable, Hashable, Sendable, Identifiable {
    public var speciesId: String
    public var name: String
    /// What it was called when met: an elder's own name.
    public var metAs: String?

    public var id: String { speciesId }

    public init(speciesId: String, name: String, metAs: String? = nil) {
        self.speciesId = speciesId
        self.name = name
        self.metAs = metAs
    }
}
