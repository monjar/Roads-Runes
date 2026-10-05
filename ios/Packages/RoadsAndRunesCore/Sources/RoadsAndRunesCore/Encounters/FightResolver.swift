import Foundation

/// Effort is damage, on the phone: a line-for-line port of the server's
/// `world_objects/fight.py`, held to it by shared fixtures
/// (`tests/fixtures/fight_tracks.json`). The phone folds it over the ride so far
/// for provisional feedback; the reckoning tells the server's verdict.
///
/// No clock is read. A point carries a position, an altitude, whether it can be
/// trusted, and the small cell it is in (for "ground covered twice pays once").
public enum FightResolver {
    public static let kinds = ["ROAD", "GROUND", "CLIMB", "RUNE", "WORD"]
    public static let carried = "CARRIED"
    public static let woken = "WOKEN"
    static let deliberate: Set<String> = ["RUNE", "WORD"]

    public struct Point: Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?
        public var ok: Bool
        /// The point's cell at `roadCellResolution` (11), for counting ground once.
        public var roadCell: String

        public init(latitude: Double, longitude: Double, altitude: Double?, ok: Bool = true, roadCell: String) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.ok = ok
            self.roadCell = roadCell
        }

        var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    }

    public struct Foe: Hashable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var holdMax: Double
        public var holdBefore: Double
        public var wants: [String]
        public var minds: [String]
        public var roadForm: String?
        public var runeToday: Bool
        public var wordToday: Bool

        public init(latitude: Double, longitude: Double, holdMax: Double, holdBefore: Double, wants: [String],
                    minds: [String] = [], roadForm: String? = nil, runeToday: Bool = false, wordToday: Bool = false) {
            self.latitude = latitude
            self.longitude = longitude
            self.holdMax = holdMax
            self.holdBefore = holdBefore
            self.wants = wants
            self.minds = minds
            self.roadForm = roadForm
            self.runeToday = runeToday
            self.wordToday = wordToday
        }

        var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
    }

    public struct RuneHit: Hashable, Sendable {
        public var shape: String
        public var index: Int

        public init(shape: String, index: Int) {
            self.shape = shape
            self.index = index
        }
    }

    public struct Report: Hashable, Sendable {
        /// SEEN_OFF, LOOSENED, UNTOUCHED or NOT_NEAR.
        public var outcome: String
        public var holdMax: Double
        public var holdBefore: Double
        public var holdAfter: Double
        public var damage: [String: Double] = [:]
        public var units: [String: Double] = [:]
        public var finisher: String?
        public var contactIndex: Int?
        public var runeLanded = false
        public var wordLanded = false

        public var taken: Double { holdBefore - holdAfter }
        public var seenOff: Bool { outcome == "SEEN_OFF" }
    }

    struct Blow {
        var kind: String
        var index: Int
        var units: Double
        var amount: Double = 0
    }

    static func affinity(_ kind: String, _ foe: Foe, _ cfg: CombatConstants) -> Double {
        if foe.wants.contains(kind) { return cfg.wants }
        if foe.minds.contains(kind) { return cfg.minds }
        return 1
    }

    static func footScale(_ kind: String, _ activity: String, _ cfg: CombatConstants) -> Double {
        ["RUN", "WALK"].contains(activity.uppercased()) ? (cfg.footScale[kind] ?? 1) : 1
    }

    static func sheetMultiplier(_ kind: String, _ pct: [String: Double], _ cfg: CombatConstants) -> Double {
        let low = cfg.sheetClamp.first ?? 0.25, high = cfg.sheetClamp.last ?? 3
        return min(high, max(low, 1 + (pct[kind] ?? 0)))
    }

    /// Hold one unit of this effort takes off this thing.
    public static func perUnit(_ kind: String, _ foe: Foe, activity: String, pct: [String: Double], cfg: CombatConstants) -> Double {
        (cfg.rates[kind] ?? 0) * footScale(kind, activity, cfg) * affinity(kind, foe, cfg) * sheetMultiplier(kind, pct, cfg)
    }

    static func finishes(_ kind: String, _ foe: Foe) -> Bool {
        deliberate.contains(kind) || foe.wants.contains(kind)
    }

    public static func resolve(
        _ points: [Point], foe: Foe, activity: String, pct: [String: Double], cfg: CombatConstants,
        newCellIndices: [Int] = [], runeHit: RuneHit? = nil, wordIndices: [Int] = []
    ) -> Report {
        var report = Report(outcome: "NOT_NEAR", holdMax: foe.holdMax, holdBefore: foe.holdBefore, holdAfter: foe.holdBefore)
        guard !points.isEmpty, foe.holdBefore > 0 else { return report }
        let distances = points.map { GeoMath.distance(foe.coordinate, $0.coordinate) }
        guard let contact = points.indices.first(where: { points[$0].ok && distances[$0] <= cfg.engageMeters }) else {
            return report
        }
        report.contactIndex = contact

        var inside: [Bool] = []
        var within = false
        for d in distances {
            if !within, d <= cfg.groundMeters { within = true } else if within, d > cfg.breakOffMeters { within = false }
            inside.append(within)
        }

        var blows: [Blow] = []
        var before: [String: Double] = ["ROAD": 0, "GROUND": 0, "CLIMB": 0]
        let newCells = Set(newCellIndices)
        var anchor: Point?
        var roadCounted = 0.0
        var roadCells: Set<String> = []
        var roadCell: String?
        var roadFresh = true
        var climbedBands: Set<Int> = []
        var lastBand: Int?
        // Each new tile counts for `groundCellScale` (the Cartographer's Atlas, 0.7.2), before contact and after.
        let tile = cfg.groundCellScale > 0 ? cfg.groundCellScale : 1
        for (i, p) in points.enumerated() {
            if newCells.contains(i) {
                if i < contact { before["GROUND", default: 0] += tile } else if inside[i] { blows.append(Blow(kind: "GROUND", index: i, units: tile)) }
            }
            guard p.ok else {
                anchor = nil
                continue
            }
            if let a = anchor {
                let step = GeoMath.distance(a.coordinate, p.coordinate)
                if step > cfg.maxJumpMeters {
                    anchor = p
                } else if step >= cfg.strideMeters {
                    if p.roadCell != roadCell {
                        roadFresh = !roadCells.contains(p.roadCell)
                        roadCells.insert(p.roadCell)
                        roadCell = p.roadCell
                    }
                    if roadFresh, i < contact {
                        before["ROAD", default: 0] += step
                    } else if roadFresh, inside[i], roadCounted < cfg.roadCapMeters {
                        let take = min(step, cfg.roadCapMeters - roadCounted)
                        roadCounted += take
                        blows.append(Blow(kind: "ROAD", index: i, units: take))
                    }
                    anchor = p
                }
            } else {
                anchor = p
            }
            if let altitude = p.altitude {
                let band = Int(floor(altitude / cfg.climbBandMeters))
                if let last = lastBand, band > last {
                    for b in (last + 1) ... band where !climbedBands.contains(b) {
                        climbedBands.insert(b)
                        if i < contact { before["CLIMB", default: 0] += cfg.climbBandMeters } else if inside[i] {
                            blows.append(Blow(kind: "CLIMB", index: i, units: cfg.climbBandMeters))
                        }
                    }
                }
                lastBand = band
            }
        }

        // Its own rune's road form lands on it; a woken rune (0.7.0) lands on anything in reach.
        if let hit = runeHit, !foe.runeToday, hit.shape == Self.woken || (foe.roadForm != nil && hit.shape == foe.roadForm) {
            blows.append(Blow(kind: "RUNE", index: max(hit.index, contact), units: 1))
        }
        if !foe.wordToday {
            let near = wordIndices.filter { $0 >= 0 && $0 < points.count && distances[$0] <= cfg.wordRadiusMeters }
            if let first = near.min() { blows.append(Blow(kind: "WORD", index: max(first, contact), units: 1)) }
        }

        if cfg.carriedFraction > 0 {
            var carried = cfg.carriedFraction * before.reduce(0) { sum, entry in
                sum + entry.value * perUnit(entry.key, foe, activity: activity, pct: pct, cfg: cfg)
            }
            carried = min(carried, cfg.carriedCap * foe.holdMax)
            if carried > 0 { blows.append(Blow(kind: carried_, index: contact, units: 1, amount: carried)) }
        }

        // Ordered as they happened; the opening blow first at contact. A stable
        // sort, as Python's is, so ties keep the order they were added in.
        blows = blows.enumerated().sorted { lhs, rhs in
            let l = (lhs.element.index, lhs.element.kind == carried_ ? 0 : 1, lhs.offset)
            let r = (rhs.element.index, rhs.element.kind == carried_ ? 0 : 1, rhs.offset)
            return l < r
        }.map(\.element)

        var hold = foe.holdBefore
        var lastLanded: String?
        for var blow in blows {
            if blow.kind != carried_ {
                blow.amount = blow.units * perUnit(blow.kind, foe, activity: activity, pct: pct, cfg: cfg)
                report.units[blow.kind, default: 0] += blow.units
            }
            if blow.amount <= 0 { continue }
            if hold - blow.amount <= 0, !finishes(blow.kind, foe) {
                blow.amount = max(0, hold - 1)
                hold = min(hold, 1)
            } else {
                hold -= blow.amount
            }
            report.damage[blow.kind, default: 0] += blow.amount
            if blow.amount > 0 { lastLanded = blow.kind }
            if blow.kind == "RUNE" { report.runeLanded = true }
            if blow.kind == "WORD" { report.wordLanded = true }
            if hold <= 0 {
                report.finisher = blow.kind
                break
            }
        }
        // The Unrung Bell (0.7.2): left with no more than this share of its most, it is
        // defeated, whatever took it there. What was left goes on the last blow that
        // landed, whose kind is the finisher (as world_objects/fight.py does).
        if finished(holdLeft: hold, holdMax: foe.holdMax, under: cfg.finishUnder) {
            if let last = lastLanded {
                report.damage[last, default: 0] += hold
                report.finisher = last
            }
            hold = 0
        }
        if hold <= 0 {
            report.outcome = "SEEN_OFF"
            report.holdAfter = 0
            return report
        }
        report.holdAfter = max(1, hold.rounded())
        report.outcome = report.taken >= 1 ? "LOOSENED" : "UNTOUCHED"
        return report
    }

    /// `FINISH_UNDER` f: after the fold, `0 < holdLeft <= f × holdMax` is defeated.
    public static func finished(holdLeft: Double, holdMax: Double, under f: Double) -> Bool {
        f > 0 && holdLeft > 0 && holdLeft <= f * holdMax
    }

    private static let carried_ = carried
}
