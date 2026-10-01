import Foundation
import RoadsAndRunesCore
import UserNotifications

/// Two reminders, both about going out: the streak that ends tonight, and the bounty
/// that arrives in the morning. Local only; nothing is sent anywhere. Rescheduled
/// every time the app goes to the background, so they always match what is true.
@MainActor
final class NudgeScheduler {
    private static let streakID = "nudge.streak"
    private static let bountyID = "nudge.bounty"
    private static let enabledKey = "nudgesEnabled"

    private let defaults = UserDefaults.standard
    /// What the World map last saw out there and where the player was, so a reminder
    /// can name something real. Set by the map; nothing is fetched to write a reminder.
    private var objects: [WorldObject] = []
    private var position: Coordinate?
    /// False in previews, unit tests and UI tests: a permission sheet would stop them.
    private let active: Bool

    init(active: Bool) {
        self.active = active
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.streakID, Self.bountyID]) }
        }
    }

    /// Asked once, after the first adventure is collected: by then the rider knows
    /// what a streak and a bounty are, so the question means something.
    func requestAuthorizationIfNeeded() async {
        guard active, isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func note(objects: [WorldObject], around position: Coordinate) {
        self.objects = objects
        self.position = position
    }

    func reschedule(character: Character?, activity: Activity, units: Units = .metric, now: Date = Date()) async {
        guard active else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.streakID, Self.bountyID])
        guard isEnabled, let character else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let calendar = Calendar.current

        // The streak ends at midnight if today has not counted yet.
        let days = character.streakDays ?? 0
        if days >= 1, character.streakActiveToday != true,
           let evening = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: now), evening > now {
            let content = UNMutableNotificationContent()
            let lures = position.map { NudgeCopy.lures(among: objects, from: $0, stillThereAt: evening) }
            let copy = NudgeCopy.streak(days: days, activity: activity, bounty: lures?.bounty, nearest: lures?.nearest, units: units)
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: evening), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.streakID, content: content, trigger: trigger))
        }

        // A new bounty every morning, worth double until midnight.
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            let content = UNMutableNotificationContent()
            let copy = NudgeCopy.bountyMorning()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: morning), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.bountyID, content: content, trigger: trigger))
        }
    }
}
