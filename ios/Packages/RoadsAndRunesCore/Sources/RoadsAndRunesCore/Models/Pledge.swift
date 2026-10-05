import Foundation

/// What a pledge is for: a creature on the map or a quest on the board.
public enum PledgeTargetKind: String, SafeEnum {
    case creature = "CREATURE"
    case quest = "QUEST"
    case unknown = "UNKNOWN"
}

/// PLEDGED until a journey keeps it; KEPT once one does. A day that passes
/// without it turns MISSED on the server, and the app never says so.
public enum PledgeStatus: String, SafeEnum {
    case pledged = "PLEDGED"
    case kept = "KEPT"
    case missed = "MISSED"
    case unknown = "UNKNOWN"
}

/// A promise to go out for one thing on one day (0.7.3, `PledgeOut`).
public struct Pledge: Codable, Hashable, Sendable {
    /// The pledged day as the phone's own calendar has it: "2026-10-06".
    public var day: String
    public var targetKind: PledgeTargetKind
    public var targetId: UUID
    public var targetName: String
    /// A `GameIcon` name for the thing's face, when the server knows one.
    public var icon: String?
    /// "HH:MM", local, when a reminder was asked for.
    public var remindAt: String?
    public var status: PledgeStatus

    public init(day: String, targetKind: PledgeTargetKind, targetId: UUID, targetName: String, icon: String? = nil,
                remindAt: String? = nil, status: PledgeStatus = .pledged) {
        self.day = day
        self.targetKind = targetKind
        self.targetId = targetId
        self.targetName = targetName
        self.icon = icon
        self.remindAt = remindAt
        self.status = status
    }

    public var isOpen: Bool { status == .pledged }
}

/// `GET /pledge?today=…`: today's pledge and tomorrow's, either or both absent.
public struct PledgeState: Codable, Hashable, Sendable {
    public var today: Pledge?
    public var tomorrow: Pledge?

    public init(today: Pledge? = nil, tomorrow: Pledge? = nil) {
        self.today = today
        self.tomorrow = tomorrow
    }

    /// The open pledge for this target, today's first.
    public func open(for targetId: UUID) -> Pledge? {
        [today, tomorrow].compactMap { $0 }.first { $0.targetId == targetId && $0.isOpen }
    }
}

/// `PUT /pledge`: one per day; a second for the same day replaces the first.
public struct PledgeRequest: Codable, Hashable, Sendable {
    public var day: String
    public var targetKind: PledgeTargetKind
    public var targetId: UUID
    public var remindAt: String?

    public init(day: String, targetKind: PledgeTargetKind, targetId: UUID, remindAt: String? = nil) {
        self.day = day
        self.targetKind = targetKind
        self.targetId = targetId
        self.remindAt = remindAt
    }
}

/// Journey's end when the journey kept today's pledge (sent only then).
public struct PledgeKept: Codable, Hashable, Sendable {
    public var kept: Bool
    public var day: String?
    public var targetKind: PledgeTargetKind?
    public var targetId: UUID?
    public var targetName: String?
    public var icon: String?
    /// "You said you would. You did."
    public var line: String?

    public init(kept: Bool, day: String? = nil, targetKind: PledgeTargetKind? = nil, targetId: UUID? = nil,
                targetName: String? = nil, icon: String? = nil, line: String? = nil) {
        self.kept = kept
        self.day = day
        self.targetKind = targetKind
        self.targetId = targetId
        self.targetName = targetName
        self.icon = icon
        self.line = line
    }

    public static let keptLine = "You said you would. You did."

    public var shownLine: String {
        guard let line, !line.isEmpty else { return Self.keptLine }
        return line
    }
}

/// When a pledge can be made (docs/ROADMAP.md, 0.7.3): in the morning for today,
/// in the evening for tomorrow. In the afternoon the day is under way and
/// tomorrow is not yet in mind, so neither is offered.
public enum PledgeWindow: String, Hashable, Sendable {
    case today
    case tomorrow

    /// Pledging for today ends at noon.
    public static let todayEndsHour = 12
    /// Pledging for tomorrow opens at five in the evening.
    public static let tomorrowOpensHour = 17

    /// The window open at `date` on the phone's calendar, if any.
    public static func current(at date: Date = Date(), calendar: Calendar = .current) -> PledgeWindow? {
        let hour = calendar.component(.hour, from: date)
        if hour < todayEndsHour { return .today }
        if hour >= tomorrowOpensHour { return .tomorrow }
        return nil
    }

    /// The day this window pledges for, as the server is sent it.
    public func day(from date: Date = Date(), calendar: Calendar = .current) -> String {
        let target = self == .today ? date : (calendar.date(byAdding: .day, value: 1, to: date) ?? date)
        return Self.dayString(target, calendar: calendar)
    }

    /// The button on a creature or quest card.
    public var buttonTitle: String {
        self == .today ? "Pledge for today" : "Pledge for tomorrow"
    }

    /// A date as "YYYY-MM-DD" on `calendar` (the phone's own day, not UTC's).
    public static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// When the reminder goes off: `remindAt` ("HH:MM") on the pledged day, if
    /// that is still to come. Nil for anything malformed or already past.
    public static func reminderDate(day: String, remindAt: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        let timeParts = remindAt.split(separator: ":").compactMap { Int($0) }
        guard dayParts.count == 3, timeParts.count == 2,
              (0..<24).contains(timeParts[0]), (0..<60).contains(timeParts[1]) else { return nil }
        var components = DateComponents()
        components.year = dayParts[0]
        components.month = dayParts[1]
        components.day = dayParts[2]
        components.hour = timeParts[0]
        components.minute = timeParts[1]
        guard let date = calendar.date(from: components), date > now else { return nil }
        return date
    }

    /// "HH:MM" for a time picked on the phone.
    public static func timeString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
