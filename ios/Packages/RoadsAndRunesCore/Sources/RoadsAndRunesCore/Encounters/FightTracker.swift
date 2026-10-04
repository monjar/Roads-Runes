import Foundation

/// Something that happened in a fight, as far as the phone can tell. The ride
/// turns these into the three fight sounds and the two wrist taps; the reckoning
/// tells the server's verdict.
public enum FightNews: Equatable, Sendable {
    /// It has noticed you: the outing came within reach of it.
    case engaged(WorldObject)
    /// A rune or the word landed on it.
    case landed(WorldObject, kind: String)
    /// It has had enough.
    case seenOff(WorldObject)
    /// Left behind with less hold than it had.
    case loosened(WorldObject)

    public var object: WorldObject {
        switch self {
        case .engaged(let o), .landed(let o, _), .seenOff(let o), .loosened(let o): return o
        }
    }
}

/// Effort is damage, live: `FightResolver` folded over the outing so far for each
/// thing it has come within reach of (docs/COMBAT.md). Provisional and on the
/// low side on purpose: every rate is cut by `underClaim`, and a rune or word
/// that landed on another outing today is not known here.
///
/// Only built when the phone has all it needs to be fair: the combat constants,
/// a character sheet, and the ground already read round the start. Without
/// those the ride says nothing about fights.
public struct FightTracker: Sendable {
    public static let underClaim = 0.95
    /// A fold over the whole outing every this many fixes, per thing in play.
    public static let evaluateEvery = 5
    /// How far back the rune matcher looks.
    public static let runeBufferMeters = 4000.0

    public struct Setup: Sendable {
        public var constants: CombatConstants
        public var sheet: CharacterSheet
        public var activity: Activity
        /// Ground already read before this outing, at `groundResolution`.
        public var knownCells: Set<String>
        public var groundResolution: Int
        public var indexing: any CellIndexing
        /// Where `knownCells` was fetched for. Outside it the phone cannot tell new
        /// ground from old, so it counts none.
        public var readBounds: BoundingBox?

        public init(constants: CombatConstants, sheet: CharacterSheet, activity: Activity, knownCells: Set<String>,
                    groundResolution: Int, indexing: any CellIndexing, readBounds: BoundingBox? = nil) {
            self.constants = constants
            self.sheet = sheet
            self.activity = activity
            self.knownCells = knownCells
            self.groundResolution = groundResolution
            self.indexing = indexing
            self.readBounds = readBounds
        }
    }

    private let setup: Setup
    private let cfg: CombatConstants
    private var foes: [UUID: (object: WorldObject, foe: FightResolver.Foe)] = [:]
    private var points: [FightResolver.Point] = []
    /// Metres made good so far, for knacks that start after a long way (Second Wind).
    private var madeGood = 0.0
    private var newCellIndices: [Int] = []
    private var wordIndices: [Int] = []
    private var runeHits: [UUID: FightResolver.RuneHit] = [:]
    private var seenCells: Set<String> = []
    private var inPlay: Set<UUID> = []
    private var inside: Set<UUID> = []
    private var said: [UUID: Set<String>] = [:]
    public private(set) var reports: [UUID: FightResolver.Report] = [:]
    public private(set) var seenOff: Set<UUID> = []

    public init(objects: [WorldObject], setup: Setup) {
        self.setup = setup
        // What the inscribed runes change that the phone can follow (Raido, Ansuz).
        var cfg = setup.sheet.fightConstants(setup.constants)
        cfg.rates = cfg.rates.mapValues { $0 * Self.underClaim }
        self.cfg = cfg
        for object in objects where object.kind == .monster && object.status == .spawned {
            guard let monster = object.monster, let holdMax = monster.holdMax, let wants = monster.wants else { continue }
            let foe = FightResolver.Foe(
                latitude: object.latitude, longitude: object.longitude, holdMax: Double(holdMax),
                holdBefore: Double(monster.holdLeft ?? holdMax), wants: wants, minds: monster.minds ?? [],
                roadForm: monster.roadForm
            )
            foes[object.id] = (object, foe)
        }
    }

    public var isEmpty: Bool { foes.isEmpty }

    /// What is left of its hold, 0…1, once the outing has reached it; nil before.
    public func holdFraction(of id: UUID) -> Double? {
        guard let entry = foes[id] else { return nil }
        guard let report = reports[id] else { return inPlay.contains(id) ? entry.foe.holdBefore / entry.foe.holdMax : nil }
        return report.holdAfter / max(1, report.holdMax)
    }

    public func fights(_ id: UUID) -> Bool { foes[id] != nil }

    /// One fix. Returns what changed, in the order it happened.
    public mutating func add(position: Coordinate, altitude: Double?, accuracy: Double?) -> [FightNews] {
        let ok = accuracy.map { $0 >= 0 && $0 <= cfg.maxAccuracyMeters } ?? true
        let roadCell = setup.indexing.cell(latitude: position.latitude, longitude: position.longitude, resolution: cfg.roadCellResolution)
        if ok, let last = points.last(where: \.ok) { madeGood += GeoMath.distance(last.coordinate, position) }
        points.append(FightResolver.Point(latitude: position.latitude, longitude: position.longitude, altitude: altitude, ok: ok, roadCell: roadCell))
        let index = points.count - 1
        let ground = setup.indexing.cell(latitude: position.latitude, longitude: position.longitude, resolution: setup.groundResolution)
        if setup.readBounds?.contains(position) ?? true, !setup.knownCells.contains(ground), seenCells.insert(ground).inserted {
            newCellIndices.append(index)
        }

        var news: [FightNews] = []
        for (id, entry) in foes where !seenOff.contains(id) {
            let distance = GeoMath.distance(position, entry.object.coordinate)
            if !inPlay.contains(id) {
                guard ok, distance <= cfg.engageMeters else { continue }
                inPlay.insert(id)
                inside.insert(id)
                news.append(.engaged(entry.object))
                news.append(contentsOf: evaluate(id))
                continue
            }
            if distance <= cfg.groundMeters { inside.insert(id) }
            if inside.contains(id), distance > cfg.breakOffMeters {
                // Left its ground: the fight so far is what it is.
                inside.remove(id)
                news.append(contentsOf: evaluate(id))
                if let report = reports[id], !report.seenOff, report.taken >= 1, said[id, default: []].insert("LOOSENED").inserted {
                    news.append(.loosened(entry.object))
                }
            } else if inside.contains(id), index % Self.evaluateEvery == 0 {
                news.append(contentsOf: evaluate(id))
            }
        }
        return news
    }

    /// A note written now: the word, for anything within reach of here.
    public mutating func wrote(note: String) -> [FightNews] {
        guard note.trimmingCharacters(in: .whitespacesAndNewlines).count >= cfg.wordMinChars, !points.isEmpty else { return [] }
        wordIndices.append(points.count - 1)
        return inPlay.subtracting(seenOff).flatMap { evaluate($0) }
    }

    // MARK: - Internals

    private mutating func evaluate(_ id: UUID) -> [FightNews] {
        guard let entry = foes[id] else { return [] }
        if runeHits[id] == nil, let hit = runeHit(for: entry.foe) { runeHits[id] = hit }
        // The build against this one, as the server works it out (elders and bounties,
        // a long way); the Historian's old places are the server's alone.
        let pct = setup.sheet.pct(
            againstElder: entry.object.tier >= 2 || entry.object.isBounty, madeGoodMeters: madeGood,
            onFoot: setup.activity == .run || setup.activity == .walk
        )
        let report = FightResolver.resolve(
            points, foe: entry.foe, activity: setup.activity.rawValue, pct: pct, cfg: cfg,
            newCellIndices: newCellIndices, runeHit: runeHits[id], wordIndices: wordIndices
        )
        reports[id] = report
        var news: [FightNews] = []
        if report.runeLanded, said[id, default: []].insert("RUNE").inserted { news.append(.landed(entry.object, kind: "RUNE")) }
        if report.wordLanded, said[id, default: []].insert("WORD").inserted { news.append(.landed(entry.object, kind: "WORD")) }
        if report.seenOff, seenOff.insert(id).inserted { news.append(.seenOff(entry.object)) }
        return news
    }

    /// Its own road form, cut with the last few kilometres of the track, as the
    /// server looks for it with the same matcher.
    private func runeHit(for foe: FightResolver.Foe) -> FightResolver.RuneHit? {
        guard let form = foe.roadForm, let wanted = RuneShape(rawValue: form), points.count >= 4 else { return nil }
        var arc = 0.0
        var from = points.count - 1
        while from > 0, arc <= Self.runeBufferMeters {
            arc += GeoMath.distance(points[from - 1].coordinate, points[from].coordinate)
            from -= 1
        }
        let track = points[from...].map(\.coordinate)
        guard let match = RuneMatcher.match(track: track, centre: foe.coordinate, threshold: setup.sheet.runeThreshold,
                                            searchRadius: setup.sheet.runeReachMeters),
              match.shape == wanted else { return nil }
        return FightResolver.RuneHit(shape: form, index: from + match.end)
    }
}
