import Foundation

// The Atlas (0.9.0): every journey on one map, a calendar of the days you went
// out, and your year in plain numbers. `GET /journal/atlas?year=`. Days stay the
// server's "YYYY-MM-DD" strings, so a journey never slips a day across time zones.

/// One journey's line on the Atlas (`traces[]`): simplified to 200 points at most.
public struct AtlasTrace: Codable, Hashable, Identifiable, Sendable {
    public var rideId: UUID?
    /// RIDE, RUN or WALK.
    public var activity: String?
    /// The day it was made, "2026-10-03" (a time may follow).
    public var date: String
    /// Google encoded polyline (precision 1e5).
    public var polyline: String

    public var id: String { rideId?.uuidString ?? "\(date)-\(polyline.prefix(24))" }

    /// "2026-10-03".
    public var day: String { String(date.prefix(10)) }

    /// The line's points.
    public var path: [Coordinate] { Polyline.decode(polyline) }

    public init(rideId: UUID?, activity: String? = nil, date: String, polyline: String) {
        self.rideId = rideId
        self.activity = activity
        self.date = date
        self.polyline = polyline
    }

    private enum CodingKeys: String, CodingKey { case rideId, activity, date, polyline }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rideId = (try? c.decodeIfPresent(UUID.self, forKey: .rideId)) ?? nil
        activity = (try? c.decodeIfPresent(String.self, forKey: .activity)) ?? nil
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        polyline = (try? c.decodeIfPresent(String.self, forKey: .polyline)) ?? ""
    }
}

/// A day with journeys in it (`days[]`), for the calendar.
public struct AtlasDay: Codable, Hashable, Identifiable, Sendable {
    /// "2026-10-03".
    public var date: String
    public var journeys: Int
    public var distanceMeters: Double

    public var id: String { day }
    public var day: String { String(date.prefix(10)) }

    public init(date: String, journeys: Int, distanceMeters: Double = 0) {
        self.date = date
        self.journeys = journeys
        self.distanceMeters = distanceMeters
    }

    private enum CodingKeys: String, CodingKey { case date, journeys, distanceMeters }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? ""
        journeys = (try? c.decodeIfPresent(Int.self, forKey: .journeys)) ?? 1
        distanceMeters = (try? c.decodeIfPresent(Double.self, forKey: .distanceMeters)) ?? 0
    }
}

/// A first of the year (`year.firsts[]`): the first creature, the first legend, the
/// first rune, the longest journey, the highest point, the first district complete.
public struct AtlasFirst: Codable, Hashable, Sendable {
    public var kind: String
    public var date: String?
    /// The server's line for it: "First creature defeated: Fen Troll".
    public var text: String

    public var day: String? { date.map { String($0.prefix(10)) } }

    public init(kind: String, date: String? = nil, text: String) {
        self.kind = kind
        self.date = date
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case kind, date, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? nil
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
    }
}

/// Your year in numbers (`year`).
public struct AtlasYear: Codable, Hashable, Sendable {
    public var journeys: Int
    public var distanceMeters: Double
    public var newTiles: Int
    public var creaturesDefeated: Int
    public var legendsDefeated: Int
    public var runesCut: Int
    public var districtsYours: Int
    /// The deeds reached this year: names or titles, as the server words them.
    public var deedsReached: [String]
    public var firsts: [AtlasFirst]

    public init(journeys: Int = 0, distanceMeters: Double = 0, newTiles: Int = 0, creaturesDefeated: Int = 0, legendsDefeated: Int = 0,
                runesCut: Int = 0, districtsYours: Int = 0, deedsReached: [String] = [], firsts: [AtlasFirst] = []) {
        self.journeys = journeys
        self.distanceMeters = distanceMeters
        self.newTiles = newTiles
        self.creaturesDefeated = creaturesDefeated
        self.legendsDefeated = legendsDefeated
        self.runesCut = runesCut
        self.districtsYours = districtsYours
        self.deedsReached = deedsReached
        self.firsts = firsts
    }

    private enum CodingKeys: String, CodingKey {
        case journeys, distanceMeters, newTiles, creaturesDefeated, legendsDefeated, runesCut, districtsYours, deedsReached, firsts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        journeys = (try? c.decodeIfPresent(Int.self, forKey: .journeys)) ?? 0
        distanceMeters = (try? c.decodeIfPresent(Double.self, forKey: .distanceMeters)) ?? 0
        newTiles = (try? c.decodeIfPresent(Int.self, forKey: .newTiles)) ?? 0
        creaturesDefeated = (try? c.decodeIfPresent(Int.self, forKey: .creaturesDefeated)) ?? 0
        legendsDefeated = (try? c.decodeIfPresent(Int.self, forKey: .legendsDefeated)) ?? 0
        runesCut = (try? c.decodeIfPresent(Int.self, forKey: .runesCut)) ?? 0
        districtsYours = (try? c.decodeIfPresent(Int.self, forKey: .districtsYours)) ?? 0
        deedsReached = Self.deeds(c)
        firsts = (try? c.decodeIfPresent([AtlasFirst].self, forKey: .firsts)) ?? []
    }

    /// Deeds as plain names, or as objects with a `title` or `name`.
    private static func deeds(_ c: KeyedDecodingContainer<CodingKeys>) -> [String] {
        if let names = try? c.decodeIfPresent([String].self, forKey: .deedsReached) { return names }
        guard let objects = try? c.decodeIfPresent([JSONValue].self, forKey: .deedsReached) else { return [] }
        return objects.compactMap { value in
            guard let object = value.objectValue else { return value.stringValue }
            return object["title"]?.stringValue ?? object["name"]?.stringValue
        }
    }
}

/// `GET /journal/atlas?year=`: the year's traces, its days and its numbers.
public struct Atlas: Codable, Hashable, Sendable {
    public var traces: [AtlasTrace]
    public var days: [AtlasDay]
    public var year: AtlasYear

    public init(traces: [AtlasTrace] = [], days: [AtlasDay] = [], year: AtlasYear = AtlasYear()) {
        self.traces = traces
        self.days = days
        self.year = year
    }

    private enum CodingKeys: String, CodingKey { case traces, days, year }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        traces = (try? c.decodeIfPresent([AtlasTrace].self, forKey: .traces)) ?? []
        days = (try? c.decodeIfPresent([AtlasDay].self, forKey: .days)) ?? []
        year = (try? c.decodeIfPresent(AtlasYear.self, forKey: .year)) ?? AtlasYear()
    }

    /// Journeys by day, "2026-10-03" to its day.
    public var daysByKey: [String: AtlasDay] {
        Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { first, second in
            AtlasDay(date: first.date, journeys: first.journeys + second.journeys, distanceMeters: first.distanceMeters + second.distanceMeters)
        })
    }

    /// The traces made on one day.
    public func traces(on day: String) -> [AtlasTrace] { traces.filter { $0.day == day } }
}

/// The calendar's month grid, worked out without a time zone: a month is its days
/// "YYYY-MM-DD", laid out from Monday in weeks of seven, blanks before the first.
public enum AtlasCalendar {
    public struct Month: Hashable, Sendable {
        public var year: Int
        public var month: Int

        public init(year: Int, month: Int) {
            self.year = year
            self.month = month
        }

        public var next: Month { month == 12 ? Month(year: year + 1, month: 1) : Month(year: year, month: month + 1) }
        public var previous: Month { month == 1 ? Month(year: year - 1, month: 12) : Month(year: year, month: month - 1) }
    }

    public static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

    public static func daysIn(_ month: Month) -> Int {
        switch month.month {
        case 2: return isLeap(month.year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// 0 for Monday … 6 for Sunday (Sakamoto's method).
    public static func weekday(year: Int, month: Int, day: Int) -> Int {
        let offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
        let y = month < 3 ? year - 1 : year
        let sunday0 = (y + y / 4 - y / 100 + y / 400 + offsets[month - 1] + day) % 7
        return (sunday0 + 6) % 7
    }

    public static func key(_ month: Month, day: Int) -> String {
        String(format: "%04d-%02d-%02d", month.year, month.month, day)
    }

    /// The month as rows of seven, Monday first; nil where no day falls.
    public static func grid(_ month: Month) -> [[Int?]] {
        let lead = weekday(year: month.year, month: month.month, day: 1)
        var cells: [Int?] = Array(repeating: nil, count: lead) + (1...daysIn(month)).map { Optional($0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    /// The month a day key falls in.
    public static func month(of day: String) -> Month? {
        let parts = day.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return nil }
        return Month(year: parts[0], month: parts[1])
    }
}
