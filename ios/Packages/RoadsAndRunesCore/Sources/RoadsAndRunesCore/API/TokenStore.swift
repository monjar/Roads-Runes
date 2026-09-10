import Foundation

/// Persists auth tokens. The app provides a Keychain-backed implementation;
/// tests and previews use `InMemoryTokenStore`.
public protocol TokenStore: AnyObject, Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens)
    func clear()
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    public init(tokens: AuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> AuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: AuthTokens) {
        lock.lock()
        self.tokens = tokens
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        tokens = nil
        lock.unlock()
    }
}
