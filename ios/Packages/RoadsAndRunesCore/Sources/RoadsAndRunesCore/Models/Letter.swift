import Foundation

/// A note to your future self, left at a place (0.7.3, `LetterOut`). It is
/// never sent to anyone: it comes back only when you pass within 60 m of where
/// it was written, a season or more later.
public struct Letter: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var latitude: Double
    public var longitude: Double
    /// The named place within 80 m of where it was written, if there was one.
    public var placeName: String?
    public var writtenAt: Date
    /// When a journey found it again; nil while it waits.
    public var shownAt: Date?

    public init(id: UUID, text: String, latitude: Double, longitude: Double, placeName: String? = nil, writtenAt: Date, shownAt: Date? = nil) {
        self.id = id
        self.text = text
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.writtenAt = writtenAt
        self.shownAt = shownAt
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

/// `POST /letters`.
public struct LetterCreate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var text: String

    public init(latitude: Double, longitude: Double, text: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.text = text
    }

    public init(at coordinate: Coordinate, text: String) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude, text: text)
    }
}

/// `GET /letters`: a plain list, or a page of one; either reads.
public struct LetterList: Decodable, Hashable, Sendable {
    public var letters: [Letter]

    public init(letters: [Letter]) {
        self.letters = letters
    }

    private enum CodingKeys: String, CodingKey { case items, letters }

    public init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([Letter].self) {
            letters = list
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        letters = try container.decodeIfPresent([Letter].self, forKey: .items)
            ?? container.decodeIfPresent([Letter].self, forKey: .letters)
            ?? []
    }
}

/// A letter found again on this journey, for Journey's end.
public struct FoundLetter: Codable, Hashable, Sendable {
    public var id: UUID?
    public var text: String
    public var writtenAt: Date
    public var placeName: String?
    public var latitude: Double?
    public var longitude: Double?
    /// "You wrote this here in October."
    public var line: String?

    public init(id: UUID? = nil, text: String, writtenAt: Date, placeName: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                line: String? = nil) {
        self.id = id
        self.text = text
        self.writtenAt = writtenAt
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.line = line
    }

    /// The server's line, or the same words made here.
    public func shownLine(now: Date = Date(), calendar: Calendar = .current) -> String {
        if let line, !line.isEmpty { return line }
        return LetterRules.foundLine(writtenAt: writtenAt, now: now, calendar: calendar)
    }
}

/// The rules for writing a letter, the same as the server's.
public enum LetterRules {
    /// The longest a letter may be, after trimming.
    public static let maxLength = 140

    /// The text as it would be sent, or nil when there is nothing to send.
    public static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }

    /// "You wrote this here in October." — with the year when it was another year.
    public static func foundLine(writtenAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: writtenAt)
        let sameYear = calendar.component(.year, from: writtenAt) == calendar.component(.year, from: now)
        return sameYear
            ? "You wrote this here in \(month)."
            : "You wrote this here in \(month) \(calendar.component(.year, from: writtenAt))."
    }
}
