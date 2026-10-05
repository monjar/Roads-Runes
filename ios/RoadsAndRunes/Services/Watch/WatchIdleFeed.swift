import Foundation
import RoadsAndRunesCore

/// Next up on the wrist (0.7.3): the streak, today's bounty and how far, the
/// quests the rider has taken and today's pledge, sent to the Watch whenever the
/// World refreshes. Nothing is fetched for it unless a Watch with the app is there.
extension AppContainer {
    func publishWatchIdle(objects: [WorldObject], around position: Coordinate?) async {
        guard watch.hasWatchApp, session.character != nil else { return }
        let quests = await watchIdleQuests(near: position)
        let pledge = await todaysPledge()
        let info = WatchIdleInfo.make(
            character: session.character, objects: objects, quests: quests, position: position,
            activity: session.defaultActivity, units: session.units, pledge: pledge,
            icon: WatchArt.icon(for:), questIcon: WatchArt.icon(for:)
        )
        watch.send(idleInfo: info)
    }

    /// The quests under way and taken, asked of the server at most every five minutes.
    private func watchIdleQuests(near position: Coordinate?) async -> [Quest] {
        if let fetched = watch.idleQuestsFetchedAt, Date().timeIntervalSince(fetched) < WatchSessionService.questsKeptFor {
            return watch.idleQuests
        }
        let here = position ?? SampleData.origin
        let limit = WatchIdleInfo.questLimit
        async let active = try? api.quests(near: here, status: .active, limit: limit, cursor: nil).items
        async let accepted = try? api.quests(near: here, status: .accepted, limit: limit, cursor: nil).items
        let (under, taken) = await (active, accepted)
        guard under != nil || taken != nil else { return watch.idleQuests }
        watch.idleQuests = (under ?? []) + (taken ?? [])
        watch.idleQuestsFetchedAt = Date()
        return watch.idleQuests
    }

    /// Today's pledge while it is still to keep; nil with the pledge switched off.
    private func todaysPledge() async -> WatchIdleInfo.Pledge? {
        guard session.isEnabled("pledge"),
              let today = try? await api.pledges(today: PledgeWindow.dayString(Date())).today, today.isOpen else { return nil }
        return WatchIdleInfo.Pledge(targetName: today.targetName, icon: today.icon)
    }
}
