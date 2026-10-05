import Foundation

// Districts (0.9.0, "The parish"): real named areas from OpenStreetMap, with a
// title after a comma ("Rotherhithe, the Riverlands"). Every type here is new
// with 0.9.0 and reads leniently: a field the server leaves out never stops the
// Journal opening.

/// Reads an id the server may send as a string or a number.
struct LenientId: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let text = try? c.decode(String.self) {
            value = text
        } else if let number = try? c.decode(Int.self) {
            value = String(number)
        } else {
            value = ""
        }
    }
}

/// The milestones of a district's explored %, as the server counts them.
public enum DistrictRules {
    /// At this % (and passed through lately) a district is yours.
    public static let yoursAtPercent = 50.0
    /// At this % it is complete.
    public static let completeAtPercent = 90.0
    /// Under this % its title is "in the fog".
    public static let titleAtPercent = 10.0
    /// How many days a district stays yours after the last visit (without Othala).
    public static let keepDays = 30
}

/// What a district holds, counted within its tiles (`GET /districts/{id}`, `ledger`).
public struct DistrictLedger: Codable, Hashable, Sendable {
    public var placesFound: Int
    public var creaturesDefeated: Int
    public var runesCut: Int
    public var questsDone: Int
    public var firstPassed: Date?
    public var lastPassed: Date?

    public init(placesFound: Int = 0, creaturesDefeated: Int = 0, runesCut: Int = 0, questsDone: Int = 0,
                firstPassed: Date? = nil, lastPassed: Date? = nil) {
        self.placesFound = placesFound
        self.creaturesDefeated = creaturesDefeated
        self.runesCut = runesCut
        self.questsDone = questsDone
        self.firstPassed = firstPassed
        self.lastPassed = lastPassed
    }

    private enum CodingKeys: String, CodingKey {
        case placesFound, creaturesDefeated, runesCut, questsDone, firstPassed, lastPassed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        placesFound = (try? c.decodeIfPresent(Int.self, forKey: .placesFound)) ?? 0
        creaturesDefeated = (try? c.decodeIfPresent(Int.self, forKey: .creaturesDefeated)) ?? 0
        runesCut = (try? c.decodeIfPresent(Int.self, forKey: .runesCut)) ?? 0
        questsDone = (try? c.decodeIfPresent(Int.self, forKey: .questsDone)) ?? 0
        firstPassed = (try? c.decodeIfPresent(Date.self, forKey: .firstPassed)) ?? nil
        lastPassed = (try? c.decodeIfPresent(Date.self, forKey: .lastPassed)) ?? nil
    }
}

/// A district the player has passed through (`DistrictOut`); with its `ledger`
/// from `GET /districts/{id}`.
public struct District: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// "Rotherhithe".
    public var name: String
    /// suburb, neighbourhood, quarter, village, town or hamlet.
    public var kind: String?
    /// "the Riverlands"; nil while it is in the fog or not yet worked out.
    public var title: String?
    /// "Rotherhithe, the Riverlands", or "Rotherhithe, in the fog".
    public var displayName: String?
    /// Explored %, 0–100, counting only tiles with a road or path; nil until those are known.
    public var percent: Double?
    public var exploredTiles: Int
    /// Tiles with a road or path in them, once known.
    public var wayTiles: Int?
    public var yours: Bool
    public var wasYours: Bool
    public var completed: Bool
    /// What it pays a week while it is yours.
    public var weeklyCoins: Int
    public var latitude: Double
    public var longitude: Double
    /// When the player first and last passed through (the list's order), if sent.
    public var firstPassed: Date?
    public var lastPassed: Date?
    /// Only from `GET /districts/{id}`.
    public var ledger: DistrictLedger?

    public init(id: String, name: String, kind: String? = nil, title: String? = nil, displayName: String? = nil, percent: Double? = nil,
                exploredTiles: Int = 0, wayTiles: Int? = nil, yours: Bool = false, wasYours: Bool = false, completed: Bool = false,
                weeklyCoins: Int = 0, latitude: Double, longitude: Double, firstPassed: Date? = nil, lastPassed: Date? = nil,
                ledger: DistrictLedger? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.title = title
        self.displayName = displayName
        self.percent = percent
        self.exploredTiles = exploredTiles
        self.wayTiles = wayTiles
        self.yours = yours
        self.wasYours = wasYours
        self.completed = completed
        self.weeklyCoins = weeklyCoins
        self.latitude = latitude
        self.longitude = longitude
        self.firstPassed = firstPassed
        self.lastPassed = lastPassed
        self.ledger = ledger
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, title, displayName, percent, exploredTiles, wayTiles, yours, wasYours, completed, weeklyCoins
        case latitude, longitude, firstPassed, lastPassed, ledger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(LenientId.self, forKey: .id))?.value ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "A district"
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
        exploredTiles = (try? c.decodeIfPresent(Int.self, forKey: .exploredTiles)) ?? 0
        wayTiles = (try? c.decodeIfPresent(Int.self, forKey: .wayTiles)) ?? nil
        yours = (try? c.decodeIfPresent(Bool.self, forKey: .yours)) ?? false
        wasYours = (try? c.decodeIfPresent(Bool.self, forKey: .wasYours)) ?? false
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? false
        weeklyCoins = (try? c.decodeIfPresent(Int.self, forKey: .weeklyCoins)) ?? 0
        latitude = (try? c.decodeIfPresent(Double.self, forKey: .latitude)) ?? 0
        longitude = (try? c.decodeIfPresent(Double.self, forKey: .longitude)) ?? 0
        firstPassed = (try? c.decodeIfPresent(Date.self, forKey: .firstPassed)) ?? nil
        lastPassed = (try? c.decodeIfPresent(Date.self, forKey: .lastPassed)) ?? nil
        ledger = (try? c.decodeIfPresent(DistrictLedger.self, forKey: .ledger)) ?? nil
    }

    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    /// "Rotherhithe, the Riverlands"; under 10% or untitled, "Rotherhithe, in the fog".
    public var fullName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return DistrictCopy.fullName(name: name, title: title, percent: percent)
    }

    /// Explored % rounded down, once the roads are known.
    public var wholePercent: Int? { percent.map { Int(max(0, min(100, $0)).rounded(.down)) } }

    /// "47% explored", or "12 tiles explored" until the roads are known.
    public var progressLine: String { DistrictCopy.progress(percent: percent, tiles: exploredTiles) }

    /// When it was first and last passed, from the ledger or the list.
    public var firstVisit: Date? { ledger?.firstPassed ?? firstPassed }
    public var lastVisit: Date? { ledger?.lastPassed ?? lastPassed }
}

/// One district a journey passed through (`summary.districts[]`).
public struct DistrictOutcome: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var title: String?
    /// "Rotherhithe, the Riverlands", or "Rotherhithe, in the fog".
    public var displayName: String?
    /// Explored % after the journey; nil until the roads are known.
    public var percent: Double?
    /// Tiles in it explored so far, and those explored for the first time on this journey.
    public var exploredTiles: Int?
    public var newTiles: Int
    /// It became yours on this journey.
    public var becameYours: Bool
    /// It reached 90% on this journey: District complete!
    public var completed: Bool

    public init(id: String, name: String, title: String? = nil, displayName: String? = nil, percent: Double? = nil, exploredTiles: Int? = nil,
                newTiles: Int = 0, becameYours: Bool = false, completed: Bool = false) {
        self.id = id
        self.name = name
        self.title = title
        self.displayName = displayName
        self.exploredTiles = exploredTiles
        self.percent = percent
        self.newTiles = newTiles
        self.becameYours = becameYours
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey { case id, name, title, displayName, percent, exploredTiles, newTiles, becameYours, completed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(LenientId.self, forKey: .id))?.value ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "A district"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        percent = (try? c.decodeIfPresent(Double.self, forKey: .percent)) ?? nil
        exploredTiles = (try? c.decodeIfPresent(Int.self, forKey: .exploredTiles)) ?? nil
        newTiles = (try? c.decodeIfPresent(Int.self, forKey: .newTiles)) ?? 0
        becameYours = (try? c.decodeIfPresent(Bool.self, forKey: .becameYours)) ?? false
        completed = (try? c.decodeIfPresent(Bool.self, forKey: .completed)) ?? false
    }

    /// "Rotherhithe, the Riverlands", or "Rotherhithe, in the fog".
    public var fullName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return DistrictCopy.fullName(name: name, title: title, percent: percent)
    }
}

/// The week's pay for the districts that are yours (`summary.districtPay`), on the
/// first journey of an ISO week.
public struct DistrictPay: Codable, Hashable, Sendable {
    public var coins: Int
    /// The names of the districts it was paid for.
    public var districts: [String]
    /// Doubled in the three days round a festival.
    public var doubled: Bool

    public init(coins: Int, districts: [String], doubled: Bool = false) {
        self.coins = coins
        self.districts = districts
        self.doubled = doubled
    }

    private enum CodingKeys: String, CodingKey { case coins, districts, doubled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coins = (try? c.decodeIfPresent(Int.self, forKey: .coins)) ?? 0
        districts = (try? c.decodeIfPresent([String].self, forKey: .districts)) ?? []
        doubled = (try? c.decodeIfPresent(Bool.self, forKey: .doubled)) ?? false
    }
}
