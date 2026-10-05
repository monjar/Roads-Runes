import Foundation

/// What the ride is doing about the nearest thing in the world: how far the chest
/// is, how much of the rune is drawn, how much of its hold is left.
public struct EncounterStatus: Equatable, Sendable {
    public var object: WorldObject
    public var distanceMeters: Double
    public var method: KillMethodKind?
    public var hint: String?
    /// 0…1 towards the method being attempted; nil for a chest or a piece.
    public var progress: Double?
    public var claimed: Bool
    /// Effort is damage: what is left of its hold, 0…1, once the outing has reached
    /// it. The ride screen draws it in tenths, with no numbers.
    public var hold: Double?

    public init(object: WorldObject, distanceMeters: Double, method: KillMethodKind? = nil, hint: String? = nil, progress: Double? = nil,
                claimed: Bool = false, hold: Double? = nil) {
        self.object = object
        self.distanceMeters = distanceMeters
        self.method = method
        self.hint = hint
        self.progress = progress
        self.claimed = claimed
        self.hold = hold
    }

    /// The hold in tenths, so the ring only redraws when it has moved a tenth.
    public var holdTenths: Int? { hold.map { Int((max(0, min(1, $0)) * 10).rounded(.up)) } }
}

/// Runs the encounter arithmetic live, on the phone, for feedback: the same pace
/// window and rune matcher the server verifies with (world_objects/claims.py), on a
/// trailing buffer of the ride. Claims here are provisional; the summary says.
///
/// With `fights` (effort is damage, 0.6.1), a creature that carries a hold is
/// fought by `FightTracker` instead, and the old check is never run on it.
public struct EncounterTracker: Sendable {
    public static let inSightMeters = 400.0
    public static let monsterNearMeters = 150.0
    /// What the server uses when an object does not carry its own radius.
    public static let claimRadius = WorldObject.defaultClaimRadius
    public static let bufferMeters = 4000.0
    public static let evaluateEvery = 5

    public private(set) var objects: [WorldObject]
    public private(set) var claimedIDs: Set<UUID> = []
    public private(set) var events: [EncounterEvent] = []
    private var buffer: [TimedPoint] = []
    private var altitudes: [Double?] = []
    private var gainWhenMet: [UUID: Double] = [:]
    private var met: Set<UUID> = []
    private var fixes = 0
    private var lastStatus: [UUID: EncounterStatus] = [:]
    private let activity: Activity
    public private(set) var fights: FightTracker?
    /// How far off something comes into sight: 400 m, or further with Kenaz or a bell (`SIGHT_M`).
    public let sightMeters: Double

    public init(objects: [WorldObject], activity: Activity, fights: FightTracker.Setup? = nil, sightMeters: Double? = nil) {
        self.objects = objects.filter { $0.status == .spawned }
        self.activity = activity
        self.sightMeters = max(Self.inSightMeters, sightMeters ?? 0)
        if let fights {
            let tracker = FightTracker(objects: self.objects, setup: fights)
            self.fights = tracker.isEmpty ? nil : tracker
        }
    }

    /// The events the phone will send with the ride, in order.
    public var pendingEvents: [EncounterEvent] { events }

    public mutating func update(
        position: Coordinate, timestamp: Date, altitude: Double?, elevationGainMeters: Double, newCellCentres: [Coordinate] = [],
        accuracy: Double? = nil
    ) -> (status: EncounterStatus?, claimed: [WorldObject], news: [FightNews]) {
        fixes += 1
        buffer.append(TimedPoint(t: timestamp.timeIntervalSince1970, coordinate: position))
        altitudes.append(altitude)
        trimBuffer()
        var newlyClaimed: [WorldObject] = []
        var news: [FightNews] = []
        if var tracker = fights {
            news = tracker.add(position: position, altitude: altitude, accuracy: accuracy)
            fights = tracker
            for case .seenOff(let object) in news where claimedIDs.insert(object.id).inserted {
                // No event: the server judges the whole trace and needs none.
                newlyClaimed.append(object)
            }
        }
        var nearest: EncounterStatus?
        for object in objects where !claimedIDs.contains(object.id) {
            let distance = GeoMath.distance(position, object.coordinate)
            var status = EncounterStatus(object: object, distanceMeters: distance)
            switch object.kind {
            case .chest, .collectable:
                if distance <= object.reachMeters ?? 30 {
                    claim(object, method: "PASS", at: position, timestamp: timestamp)
                    newlyClaimed.append(object)
                    continue
                }
            case .monster where fights?.fights(object.id) == true:
                status.hold = fights?.holdFraction(of: object.id)
            case .monster:
                if distance <= Self.monsterNearMeters, !met.contains(object.id) {
                    met.insert(object.id)
                    gainWhenMet[object.id] = elevationGainMeters
                }
                if met.contains(object.id), fixes % Self.evaluateEvery == 0 || distance <= Self.monsterNearMeters {
                    let verdict = fight(object, position: position, elevationGainMeters: elevationGainMeters, newCellCentres: newCellCentres)
                    status.method = verdict.method
                    status.hint = verdict.hint
                    status.progress = verdict.progress
                    lastStatus[object.id] = status
                    if let won = verdict.won {
                        claim(object, method: won.rawValue, at: position, timestamp: timestamp)
                        newlyClaimed.append(object)
                        continue
                    }
                } else if let remembered = lastStatus[object.id] {
                    status.method = remembered.method
                    status.hint = remembered.hint
                    status.progress = remembered.progress
                } else if let first = object.monster?.killMethods.first {
                    status.method = first.method
                    status.hint = first.hint
                }
            case .unknown:
                continue
            }
            if distance <= sightMeters, nearest == nil || distance < nearest!.distanceMeters {
                nearest = status
            }
        }
        return (nearest, newlyClaimed, news)
    }

    /// The Scribe's way in: a note (and, for anyone else, a photo) within reach of it.
    /// Fought by effort, a note is the word: it is sent with the ride for the server
    /// to place on the trace, lands on whatever is near, and claims nothing by itself.
    public mutating func markLore(_ objectId: UUID, at position: Coordinate?, timestamp: Date, note: String?, photoTaken: Bool)
        -> (event: EncounterEvent, news: [FightNews])? {
        guard objects.contains(where: { $0.id == objectId }), !claimedIDs.contains(objectId) else { return nil }
        let event = EncounterEvent(objectId: objectId, method: KillMethodKind.lore.rawValue, occurredAt: timestamp, latitude: position?.latitude, longitude: position?.longitude, note: note, photoTaken: photoTaken)
        events.append(event)
        if var tracker = fights, tracker.fights(objectId) {
            let news = tracker.wrote(note: note ?? "")
            fights = tracker
            for case .seenOff(let object) in news { claimedIDs.insert(object.id) }
            return (event, news)
        }
        claimedIDs.insert(objectId)
        return (event, [])
    }

    // MARK: - Crash recovery (0.7.2)

    /// What this tracker holds that a crash must not lose: what was in play, what
    /// was claimed, and the events still to be sent with the ride.
    public func gameState(quarryId: UUID?, fights setup: FightSetupState?) -> RideGameState {
        RideGameState(objects: objects, claimedIDs: Array(claimedIDs), events: events, quarryId: quarryId, sightMeters: sightMeters,
                      fights: setup)
    }

    /// The game layer put back after a crash: the same things in play, what was
    /// claimed and noted kept, and the outing so far folded again, silently, so the
    /// fights stand where they stood. Something the outing reached after the last
    /// save is claimed by the replay and joins the events, as it would have.
    public init(restoring game: RideGameState, activity: Activity, indexing: any CellIndexing, replaying fixes: [LocationFix]) {
        self.init(objects: game.objects, activity: activity, fights: game.fights?.setup(activity: activity, indexing: indexing),
                  sightMeters: game.sightMeters)
        claimedIDs = Set(game.claimedIDs)
        events = game.events
        // A note lands on what is near when it was written: put each back at its time.
        let notes = game.events
            .filter { $0.method == KillMethodKind.lore.rawValue && !($0.note ?? "").isEmpty }
            .sorted { $0.occurredAt < $1.occurredAt }
        var next = 0
        var gain = 0.0
        var lastAltitude: Double?
        for fix in fixes {
            while next < notes.count, notes[next].occurredAt < fix.timestamp {
                replay(note: notes[next].note ?? "")
                next += 1
            }
            if let altitude = fix.altitude {
                if let last = lastAltitude, altitude > last { gain += altitude - last }
                lastAltitude = altitude
            }
            _ = update(position: fix.coordinate, timestamp: fix.timestamp, altitude: fix.altitude, elevationGainMeters: gain,
                       accuracy: fix.horizontalAccuracy)
        }
        while next < notes.count {
            replay(note: notes[next].note ?? "")
            next += 1
        }
    }

    private mutating func replay(note: String) {
        guard var tracker = fights else { return }
        let news = tracker.wrote(note: note)
        fights = tracker
        for case .seenOff(let object) in news { claimedIDs.insert(object.id) }
    }

    // MARK: - Internals

    private mutating func claim(_ object: WorldObject, method: String, at position: Coordinate, timestamp: Date) {
        claimedIDs.insert(object.id)
        events.append(EncounterEvent(objectId: object.id, method: method, occurredAt: timestamp, latitude: position.latitude, longitude: position.longitude))
    }

    private mutating func trimBuffer() {
        var arc = 0.0
        var keepFrom = buffer.count - 1
        while keepFrom > 0 {
            arc += GeoMath.distance(buffer[keepFrom - 1].coordinate, buffer[keepFrom].coordinate)
            if arc > Self.bufferMeters { break }
            keepFrom -= 1
        }
        if keepFrom > 0 {
            buffer.removeFirst(keepFrom)
            altitudes.removeFirst(keepFrom)
        }
    }

    private struct Verdict {
        var method: KillMethodKind?
        var hint: String?
        var progress: Double?
        var won: KillMethodKind?
    }

    private func fight(_ object: WorldObject, position: Coordinate, elevationGainMeters: Double, newCellCentres: [Coordinate]) -> Verdict {
        var best = Verdict()
        for method in object.monster?.killMethods ?? [] {
            var progress = 0.0
            switch method.method {
            case .pace:
                let window = method.double("windowMeters") ?? 1000
                let target = method.params["paceSecPerKm"]?.objectValue?[activity.rawValue]?.doubleValue ?? method.double("paceSecPerKm") ?? 150
                let radius = method.double("searchRadiusMeters") ?? 1000
                let near = buffer.map { GeoMath.distance($0.coordinate, object.coordinate) <= radius }
                if let found = PaceFinder.bestWindow(buffer, windowMeters: window, speedCap: Self.speedCap(activity), near: near) {
                    progress = min(1, target / found.paceSecondsPerKm)
                } else {
                    progress = min(0.95, nearMeters(within: radius, of: object) / window)
                }
            case .rune:
                let wanted = method.params["shape"]?.stringValue.flatMap(RuneShape.init(rawValue:))
                let threshold = method.double("scoreThreshold") ?? 0.22
                let radius = method.double("searchRadiusMeters") ?? 1000
                let minLength = method.double("minLengthMeters") ?? 300
                // Nothing counts until the shape is there; being nearby is not tracing.
                if nearMeters(within: radius, of: object) >= minLength, let wanted,
                   let match = RuneMatcher.match(track: buffer.map(\.coordinate), centre: object.coordinate, threshold: threshold, searchRadius: radius, minLength: minLength, maxLength: method.double("maxLengthMeters") ?? 4000),
                   match.shape == wanted {
                    progress = 1
                } else {
                    progress = 0.05
                }
            case .climb:
                let gain = elevationGainMeters - (gainWhenMet[object.id] ?? elevationGainMeters)
                progress = min(1, gain / max(1, method.double("gainMeters") ?? 40))
            case .explore:
                let within = method.double("withinMeters") ?? 1500
                let cleared = newCellCentres.filter { GeoMath.distance($0, object.coordinate) <= within }.count
                progress = min(1, Double(cleared) / max(1, method.double("cells") ?? 3))
            case .lore, .unknown:
                continue
            }
            if best.progress == nil || progress > best.progress! {
                best = Verdict(method: method.method, hint: method.hint, progress: progress, won: progress >= 1 ? method.method : nil)
            }
            if best.won != nil { break }
        }
        return best
    }

    private func nearMeters(within radius: Double, of object: WorldObject) -> Double {
        var total = 0.0
        for (a, b) in zip(buffer, buffer.dropFirst()) where GeoMath.distance(b.coordinate, object.coordinate) <= radius {
            total += GeoMath.distance(a.coordinate, b.coordinate)
        }
        return total
    }

    static func speedCap(_ activity: Activity) -> Double {
        switch activity {
        case .run: return 8
        case .walk: return 4
        default: return 25
        }
    }
}
