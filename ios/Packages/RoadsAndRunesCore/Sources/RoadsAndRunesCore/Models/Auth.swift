import Foundation

/// Tokens held by the client. `expiresAt` is derived from `expiresIn`.
public struct AuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public init(response: TokenResponse, now: Date = Date()) {
        self.init(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    public func isExpired(at date: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        date.addingTimeInterval(leeway) >= expiresAt
    }
}

/// `POST /auth/apple`, `/auth/refresh`, `/auth/dev` response.
public struct TokenResponse: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Int
    public var isNewUser: Bool
    public var user: User

    public init(accessToken: String, refreshToken: String, expiresIn: Int, isNewUser: Bool, user: User) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.isNewUser = isNewUser
        self.user = user
    }
}

public struct AppleFullName: Codable, Hashable, Sendable {
    public var givenName: String?
    public var familyName: String?

    public init(givenName: String? = nil, familyName: String? = nil) {
        self.givenName = givenName
        self.familyName = familyName
    }
}

public struct AppleSignInRequest: Codable, Hashable, Sendable {
    public var identityToken: String
    public var authorizationCode: String?
    public var fullName: AppleFullName?

    public init(identityToken: String, authorizationCode: String? = nil, fullName: AppleFullName? = nil) {
        self.identityToken = identityToken
        self.authorizationCode = authorizationCode
        self.fullName = fullName
    }
}

public struct DevSignInRequest: Codable, Hashable, Sendable {
    public var subject: String
    public var displayName: String

    public init(subject: String, displayName: String = "Dev Rider") {
        self.subject = subject
        self.displayName = displayName
    }
}

public struct RefreshRequest: Codable, Hashable, Sendable {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}
