import Foundation
import Observation
import RoadsAndRunesCore

/// Today's and tomorrow's pledge (0.7.3), behind the `pledge` flag: what the
/// creature and quest cards offer, the reminder, the row on Next up. A missed
/// pledge is never shown: the server stops sending it, and nothing here keeps it.
@MainActor
@Observable
final class PledgeStore {
    private(set) var state = PledgeState()
    private(set) var busy = false
    var error: String?

    @ObservationIgnored private let api: any RoadsAndRunesAPI
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let nudges: NudgeScheduler
    @ObservationIgnored private let calendar: Calendar

    init(api: any RoadsAndRunesAPI, session: SessionStore, nudges: NudgeScheduler, calendar: Calendar = .current) {
        self.api = api
        self.session = session
        self.nudges = nudges
        self.calendar = calendar
    }

    var isOn: Bool { session.isEnabled("pledge") }

    /// Today's pledge while it is still to keep.
    var today: Pledge? { state.today.flatMap { $0.isOpen ? $0 : nil } }

    /// The open pledge for a creature or quest, today's or tomorrow's.
    func open(for targetId: UUID) -> Pledge? { state.open(for: targetId) }

    /// The pledge `window` would replace, if any: one a day.
    func existing(in window: PledgeWindow) -> Pledge? {
        let pledge = window == .today ? state.today : state.tomorrow
        return pledge?.isOpen == true ? pledge : nil
    }

    func refresh(now: Date = Date()) async {
        guard isOn else { return set(PledgeState()) }
        do {
            set(try await api.pledges(today: PledgeWindow.dayString(now, calendar: calendar)))
            error = nil
        } catch {
            // Not worth a line on every map: the cards simply offer a pledge again.
        }
    }

    /// Pledges a creature or a quest for the window's day, with a reminder at `remindAt` if one was picked.
    @discardableResult
    func pledge(_ kind: PledgeTargetKind, id: UUID, window: PledgeWindow, remindAt: Date?, now: Date = Date()) async -> Bool {
        busy = true
        defer { busy = false }
        let day = window.day(from: now, calendar: calendar)
        do {
            let pledge = try await api.pledge(PledgeRequest(
                day: day, targetKind: kind, targetId: id, remindAt: remindAt.map { PledgeWindow.timeString($0, calendar: calendar) }
            ))
            var next = state
            if window == .today { next.today = pledge } else { next.tomorrow = pledge }
            set(next)
            error = nil
            await nudges.schedulePledgeReminder(for: pledge, now: now)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func cancel(_ pledge: Pledge) async {
        busy = true
        defer { busy = false }
        do {
            try await api.cancelPledge(day: pledge.day)
        } catch let error as APIError where error.isNotFound {
            // Already gone: what matters is that it is not on screen.
        } catch {
            self.error = error.localizedDescription
            return
        }
        var next = state
        if next.today?.day == pledge.day { next.today = nil }
        if next.tomorrow?.day == pledge.day { next.tomorrow = nil }
        set(next)
        if pledge.remindAt != nil { nudges.cancelPledgeReminder() }
        error = nil
    }

    /// Journey's end: a kept pledge needs no reminder any more.
    func journeyEnded(_ summary: AdventureSummary) async {
        guard summary.pledge?.kept == true else { return }
        nudges.cancelPledgeReminder()
        await refresh()
    }

    private func set(_ new: PledgeState) {
        state = new
        // The home-screen widget shows today's pledge while it is to keep.
        WidgetSnapshotWriter.shared.pledge = today.map { WidgetSnapshot.Pledge(targetName: $0.targetName, icon: $0.icon) }
    }
}
