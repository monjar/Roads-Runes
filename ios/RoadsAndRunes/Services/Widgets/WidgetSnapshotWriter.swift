import Foundation
import RoadsAndRunesCore
import WidgetKit

/// Leaves what the widgets show in the app group (0.7.3): the streak and level
/// from the character, the bounty from the last world loaded, the week's quest,
/// the Codex count and today's pledge. The widgets read only this; they never
/// go to the network.
///
/// Written when the World loads, after Journey's end, when the character changes
/// and when the app goes to the background, then every widget timeline is reloaded.
@MainActor
final class WidgetSnapshotWriter {
    static let shared = WidgetSnapshotWriter()

    /// The week's quest and the Codex are asked for at most this often, unless a
    /// journey has just ended.
    static let fetchInterval: TimeInterval = 15 * 60

    private weak var container: AppContainer?
    private let defaults: UserDefaults?
    private let reload: () -> Void
    private var weekNotice: WeekNotice?
    private var codex: CodexCounts?
    /// Today's pledge while it is still to keep, as the app's `PledgeStore` has it.
    var pledge: WidgetSnapshot.Pledge? {
        didSet { if pledge != oldValue { write() } }
    }
    private var fetchedAt: Date?
    private var fetching = false
    private(set) var lastWritten: WidgetSnapshot?

    init(defaults: UserDefaults? = WidgetSnapshot.sharedDefaults, reload: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }) {
        self.defaults = defaults
        self.reload = reload
    }

    func attach(_ container: AppContainer) {
        self.container = container
    }

    // MARK: When to write

    /// The World loaded its creatures: the bounty and how far it is may have moved.
    func worldLoaded() {
        Task { await refresh() }
    }

    /// Journey's end: the streak, the week's quest and the Codex have all moved.
    func journeyEnded() {
        Task { await refresh(force: true) }
    }

    /// Leaving the app: no time for the network, write what is known.
    func appBackgrounded() {
        write()
    }

    /// Asks for the week's quest and the Codex when they are stale, then writes.
    func refresh(force: Bool = false, now: Date = Date()) async {
        guard let container, container.session.state == .ready else {
            write()
            return
        }
        let stale = fetchedAt.map { now.timeIntervalSince($0) >= Self.fetchInterval } ?? true
        if (force || stale) && !fetching {
            fetching = true
            async let week = try? container.api.weekNotice()
            async let codex = try? container.api.codex()
            let (fetchedWeek, fetchedCodex) = await (week, codex)
            if let fetchedWeek { weekNotice = fetchedWeek }
            if let fetchedCodex { self.codex = fetchedCodex.counts }
            fetchedAt = now
            fetching = false
        }
        write(now: now)
    }

    /// Builds the snapshot from what the app holds and writes it; signed out, it
    /// clears it so the widget says to open the app.
    func write(now: Date = Date()) {
        guard let container else { return }
        let session = container.session
        switch session.state {
        case .loading:
            return
        case .signedOut, .needsCharacter:
            clear()
            return
        case .ready:
            break
        }
        let world = container.worldCache.load()
        let snapshot = Self.snapshot(
            character: session.character, objects: world?.objects ?? [],
            position: container.location.lastFix?.coordinate ?? world?.center,
            weekNotice: weekNotice, codex: codex, pledge: pledge, units: session.units, now: now
        )
        save(snapshot)
    }

    func clear() {
        guard lastWritten != nil || WidgetSnapshot.read(from: defaults) != nil else { return }
        WidgetSnapshot.clear(in: defaults)
        lastWritten = nil
        reload()
    }

    /// Writes and reloads only when something a widget shows has changed (the
    /// time it was written aside), so the widgets' reload budget is not spent on nothing.
    func save(_ snapshot: WidgetSnapshot) {
        var comparable = snapshot
        comparable.updatedAt = lastWritten?.updatedAt ?? snapshot.updatedAt
        let sameDay = lastWritten.map { Calendar.current.isDate($0.updatedAt, inSameDayAs: snapshot.updatedAt) } ?? false
        if sameDay, comparable == lastWritten { return }
        guard snapshot.write(to: defaults) else { return }
        lastWritten = snapshot
        reload()
    }

    /// The parts of the session a widget shows, for the app to write again when
    /// one of them changes (signing in or out among them).
    struct Watched: Equatable {
        let state: SessionStore.State
        let streakDays: Int?
        let streakActiveToday: Bool?
        let level: Int?
        let characterClass: CharacterClass?
        let units: Units
    }

    static func watched(_ session: SessionStore) -> Watched {
        let character = session.character
        return Watched(state: session.state, streakDays: character?.streakDays, streakActiveToday: character?.streakActiveToday,
                       level: character?.overallLevel, characterClass: character?.characterClass, units: session.units)
    }

    // MARK: The snapshot

    /// The snapshot from the app's own state, as a pure function for tests.
    static func snapshot(
        character: Character?, objects: [WorldObject], position: Coordinate?, weekNotice: WeekNotice?, codex: CodexCounts?,
        pledge: WidgetSnapshot.Pledge?, units: Units, now: Date = Date()
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            updatedAt: now,
            streakDays: character?.streakDays ?? 0,
            streakActiveToday: character?.streakActiveToday ?? false,
            bounty: bounty(in: objects, from: position, now: now),
            weekNotice: weekNotice.map { WidgetSnapshot.WeekNotice(title: $0.title, progress: $0.fraction, done: $0.done) },
            codexMet: codex?.creaturesSeen,
            codexTotal: codex?.creaturesTotal,
            level: character?.overallLevel,
            className: character.map { ClassStyle.name($0.characterClass) },
            pledge: pledge,
            units: units
        )
    }

    /// Today's bounty: a creature still out, and the nearest one if somehow there are two.
    static func bounty(in objects: [WorldObject], from position: Coordinate?, now: Date = Date()) -> WidgetSnapshot.Bounty? {
        let live = objects.filter { $0.isBounty && $0.kind == .monster && $0.status == .spawned && $0.expiresAt > now }
        let distance: (WorldObject) -> Double? = { object in position.map { GeoMath.distance($0, object.coordinate) } }
        guard let bounty = live.min(by: { (distance($0) ?? 0) < (distance($1) ?? 0) }) else { return nil }
        return WidgetSnapshot.Bounty(name: bounty.name, icon: WatchArt.icon(for: bounty), distanceMeters: distance(bounty), expiresAt: bounty.expiresAt)
    }
}
