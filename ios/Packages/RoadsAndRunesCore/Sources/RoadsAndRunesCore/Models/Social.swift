import Foundation

public struct FriendSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var avatarUrl: String?
    public var characterClass: CharacterClass?
    public var overallLevel: Int?
    public var title: String?
    public var since: Date?

    public init(id: UUID, displayName: String, avatarUrl: String? = nil, characterClass: CharacterClass? = nil, overallLevel: Int? = nil, title: String? = nil, since: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.characterClass = characterClass
        self.overallLevel = overallLevel
        self.title = title
        self.since = since
    }
}

public struct FriendRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var user: FriendSummary
    public var createdAt: Date

    public init(id: UUID, user: FriendSummary, createdAt: Date) {
        self.id = id
        self.user = user
        self.createdAt = createdAt
    }
}

public struct FriendRequests: Codable, Hashable, Sendable {
    public var incoming: [FriendRequest]
    public var outgoing: [FriendRequest]

    public init(incoming: [FriendRequest] = [], outgoing: [FriendRequest] = []) {
        self.incoming = incoming
        self.outgoing = outgoing
    }
}

public struct FriendRequestCreate: Codable, Hashable, Sendable {
    public var userId: UUID

    public init(userId: UUID) {
        self.userId = userId
    }
}

/// `POST /friends/requests` response.
public struct FriendRequestResult: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var status: String

    public init(id: UUID, status: String) {
        self.id = id
        self.status = status
    }
}

public struct FeedEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var eventType: FeedEventType
    public var user: FriendSummary
    public var payload: [String: JSONValue]
    public var createdAt: Date

    public init(id: UUID, eventType: FeedEventType, user: FriendSummary, payload: [String: JSONValue] = [:], createdAt: Date) {
        self.id = id
        self.eventType = eventType
        self.user = user
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct PartyMember: Codable, Hashable, Identifiable, Sendable {
    public var user: FriendSummary
    public var role: String
    public var status: String
    public var questId: UUID?

    public var id: UUID { user.id }

    public init(user: FriendSummary, role: String, status: String, questId: UUID? = nil) {
        self.user = user
        self.role = role
        self.status = status
        self.questId = questId
    }
}

public struct Party: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var ownerId: UUID
    public var questId: UUID?
    public var routeId: UUID?
    public var status: PartyStatus
    public var completionRule: CompletionRule
    public var members: [PartyMember]
    public var createdAt: Date

    public init(id: UUID, ownerId: UUID, questId: UUID? = nil, routeId: UUID? = nil, status: PartyStatus, completionRule: CompletionRule, members: [PartyMember], createdAt: Date) {
        self.id = id
        self.ownerId = ownerId
        self.questId = questId
        self.routeId = routeId
        self.status = status
        self.completionRule = completionRule
        self.members = members
        self.createdAt = createdAt
    }
}

public struct PartyCreate: Codable, Hashable, Sendable {
    public var questId: UUID
    public var memberIds: [UUID]

    public init(questId: UUID, memberIds: [UUID] = []) {
        self.questId = questId
        self.memberIds = memberIds
    }
}

public struct PartyInvite: Codable, Hashable, Sendable {
    public var userId: UUID

    public init(userId: UUID) {
        self.userId = userId
    }
}
