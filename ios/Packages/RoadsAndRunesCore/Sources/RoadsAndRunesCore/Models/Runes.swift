import Foundation

/// One rune that can be held (`GET /runes`, 0.7.0): whether it is, its rank and
/// stones, whether it is inscribed, and what it does.
public struct RuneInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// ROAD or GROUND.
    public var six: String
    public var gloss: String?
    public var roadForm: String?
    public var held: Bool
    public var rank: Int
    public var shards: Int
    public var inscribed: Bool
    /// What it does inscribed, at its rank (or at rank I, for one not yet held).
    public var rule: String
    /// What the next rank costs: stones of it and coins.
    public var nextRank: RankCost?

    public struct RankCost: Codable, Hashable, Sendable {
        public var shards: Int
        public var coins: Int

        public init(shards: Int, coins: Int) {
            self.shards = shards
            self.coins = coins
        }
    }

    public var canRaise: Bool { held && (nextRank.map { shards >= $0.shards } ?? false) }

    public init(id: String, name: String, six: String, gloss: String? = nil, roadForm: String? = nil, held: Bool, rank: Int = 0,
                shards: Int = 0, inscribed: Bool = false, rule: String, nextRank: RankCost? = nil) {
        self.id = id
        self.name = name
        self.six = six
        self.gloss = gloss
        self.roadForm = roadForm
        self.held = held
        self.rank = rank
        self.shards = shards
        self.inscribed = inscribed
        self.rule = rule
        self.nextRank = nextRank
    }
}

/// `GET /runes`: every rune, what is inscribed, and the slots the level opens.
public struct RunesState: Codable, Hashable, Sendable {
    public var runes: [RuneInfo]
    public var inscribed: [String]
    public var slots: Int
    public var slotsAtLevel: [Int]

    public init(runes: [RuneInfo], inscribed: [String], slots: Int, slotsAtLevel: [Int]) {
        self.runes = runes
        self.inscribed = inscribed
        self.slots = slots
        self.slotsAtLevel = slotsAtLevel
    }
}

/// `PUT /runes/inscribed`.
public struct InscribeRequest: Codable, Hashable, Sendable {
    public var runes: [String]

    public init(runes: [String]) {
        self.runes = runes
    }
}

/// A rune cut with a track (`GET /runes/cuts`): the mark on the maps.
public struct RuneCutInfo: Codable, Hashable, Identifiable, Sendable {
    public var runeId: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var woke: Bool
    /// WAKING, FIGHT or QUEST.
    public var source: String
    public var placeName: String?
    public var cutAt: Date
    public var rideId: String?

    public var id: String { "\(runeId)-\(source)-\(rideId ?? "")-\(cutAt.timeIntervalSince1970)" }
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }

    public init(runeId: String, name: String, latitude: Double, longitude: Double, woke: Bool, source: String,
                placeName: String? = nil, cutAt: Date, rideId: String? = nil) {
        self.runeId = runeId
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.woke = woke
        self.source = source
        self.placeName = placeName
        self.cutAt = cutAt
        self.rideId = rideId
    }
}

/// `GET /character/deeds`: a record, not points (0.7.0).
public struct DeedsState: Codable, Hashable, Sendable {
    public struct Deed: Codable, Hashable, Identifiable, Sendable {
        /// LEGS, LUNGS, EYES, HAND or INK.
        public var id: String
        public var name: String
        public var what: String
        public var unit: String
        public var value: Double
        public var tier: Int
        public var next: Double?
        public var title: String?
        public var frame: String?

        public init(id: String, name: String, what: String, unit: String, value: Double, tier: Int, next: Double? = nil,
                    title: String? = nil, frame: String? = nil) {
            self.id = id
            self.name = name
            self.what = what
            self.unit = unit
            self.value = value
            self.tier = tier
            self.next = next
            self.title = title
            self.frame = frame
        }
    }

    public struct Record: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var unit: String
        public var value: Double?

        public init(id: String, name: String, unit: String, value: Double? = nil) {
            self.id = id
            self.name = name
            self.unit = unit
            self.value = value
        }
    }

    public var deeds: [Deed]
    public var records: [Record]

    public init(deeds: [Deed], records: [Record]) {
        self.deeds = deeds
        self.records = records
    }
}

/// What an outing did for the deeds (`summary.deeds`).
public struct DeedsOutcome: Codable, Hashable, Sendable {
    public struct Reached: Codable, Hashable, Sendable {
        public var deed: String
        public var name: String
        public var tier: Int
        public var title: String?
        public var frame: String?
    }

    public struct Beaten: Codable, Hashable, Sendable {
        public var record: String
        public var name: String
        public var value: Double
        public var unit: String
    }

    public var reached: [Reached]
    public var records: [Beaten]
}

/// A rune stone picked up on an outing (`summary.runesFound`).
public struct RuneFound: Codable, Hashable, Sendable {
    public var rune: String
    /// The first stone of it: it is held now.
    public var new: Bool
    public var rank: Int
    public var shards: Int
}

/// `POST /routes/rune`: a route in a rune's road form, from here.
public struct RuneRideRequest: Codable, Hashable, Sendable {
    public var origin: Coordinate
    public var rune: String
    public var activity: Activity?
    public var bikeId: UUID?

    public init(origin: Coordinate, rune: String, activity: Activity? = nil, bikeId: UUID? = nil) {
        self.origin = origin
        self.rune = rune
        self.activity = activity
        self.bikeId = bikeId
    }
}

public struct RuneRideResponse: Codable, Hashable, Sendable {
    public var alternatives: [RouteOption]
    public var rune: String
    public var roadForm: String
    /// "Cut Raido here: a loop, about 2.4 km."
    public var hint: String
    public var engine: String?
}
