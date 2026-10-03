import Foundation

/// A creature's face as the server describes it: a body, a feature and what it
/// stands on (`world_objects.json`, `sigil`). Drawn by RoadsAndRunesArt.
public struct CreatureSigil: Codable, Hashable, Sendable {
    public var body: String
    public var feature: String
    public var mark: String

    public init(body: String, feature: String, mark: String) {
        self.body = body
        self.feature = feature
        self.mark = mark
    }
}

/// `GET /codex`: the world in its own words, and what this player has met of it.
public struct Codex: Codable, Hashable, Sendable {
    public var chapters: [CodexChapter]
    public var entries: [CodexEntry]
    public var creatures: [CodexCreature]
    public var runes: [CodexRune]
    public var sixes: [CodexSix]
    public var people: [CodexPerson]
    public var counts: CodexCounts

    public init(chapters: [CodexChapter], entries: [CodexEntry], creatures: [CodexCreature], runes: [CodexRune],
                sixes: [CodexSix], people: [CodexPerson], counts: CodexCounts) {
        self.chapters = chapters
        self.entries = entries
        self.creatures = creatures
        self.runes = runes
        self.sixes = sixes
        self.people = people
        self.counts = counts
    }

    public func entries(in chapter: String) -> [CodexEntry] {
        entries.filter { $0.chapter == chapter }
    }
}

public struct CodexChapter: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
}

public struct CodexEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var chapter: String
    public var title: String
    public var body: [String]
    public var by: String
    public var byName: String
    public var characterClass: String?

    public init(id: String, chapter: String, title: String, body: [String], by: String, byName: String, characterClass: String? = nil) {
        self.id = id
        self.chapter = chapter
        self.title = title
        self.body = body
        self.by = by
        self.byName = byName
        self.characterClass = characterClass
    }
}

public enum CodexState: String, SafeEnum {
    case unseen = "UNSEEN"
    case seen = "SEEN"
    case met = "MET"
    case unknown
}

public struct CodexElder: Codable, Hashable, Sendable {
    public var tier: Int
    public var name: String
    public var flavour: String
    public var seen: Bool
}

public struct CodexCreature: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var family: String
    public var flavour: String
    public var hint: String
    public var page: String
    public var leaves: String
    /// Kinds of effort it wants and shrugs at; shown only once `effort_combat` is on.
    public var wants: [String]
    public var minds: [String]
    public var rune: String?
    public var elders: [CodexElder]
    public var sigil: CreatureSigil
    public var state: CodexState
    public var seenCount: Int
    public var seenOffCount: Int
    public var firstSeenAt: Date?
    public var lastSeenOffAt: Date?
}

public enum RuneState: String, SafeEnum {
    case held = "HELD"
    case notFound = "NOT_FOUND"
    case unknown
}

public struct CodexRune: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var order: Int
    public var six: String
    public var gloss: String
    public var lends: String
    /// LOOP, TRIANGLE, SQUARE, ZIGZAG, NOTE, STOP, or nil when it cannot be cut on a road yet.
    public var roadForm: String?
    public var state: RuneState
    public var found: Int
}

public struct CodexSix: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var how: String
}

public struct CodexPerson: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var role: String
    public var posts: String
    public var page: String
    public var pageBy: String
    public var lines: [String]
}

public struct CodexCounts: Codable, Hashable, Sendable {
    public var creaturesSeenOff: Int
    public var creaturesSeen: Int
    public var creaturesTotal: Int
    public var runesHeld: Int
    public var runesTotal: Int
}
