import Foundation

/// A real reward set against coins (0.7.3): "New bar tape" at 5,000. It lives
/// on this phone only and is a bar against the purse, nothing more.
public struct SavingsGoal: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var coins: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, coins: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.coins = coins
        self.createdAt = createdAt
    }

    /// How much of it the purse covers, 0…1.
    public func fraction(purse: Int) -> Double {
        guard coins > 0 else { return 1 }
        return min(1, max(0, Double(purse) / Double(coins)))
    }

    public func isReached(purse: Int) -> Bool { purse >= coins }

    /// The longest name kept, and the most coins a goal may ask for.
    public static let maxNameLength = 40
    public static let maxCoins = 10_000_000

    /// A goal from what was typed, or nil when there is no name or no amount.
    public static func make(name: String, coins: Int, now: Date = Date()) -> SavingsGoal? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1...maxCoins).contains(coins) else { return nil }
        return SavingsGoal(name: String(trimmed.prefix(maxNameLength)), coins: coins, createdAt: now)
    }
}

/// The savings goals, kept in the app group's defaults so a widget could read
/// them one day. Oldest first, the order they were set.
public struct SavingsGoalStore {
    public static let key = "savings.goals.v1"
    public static let appGroup = "group.com.roadsandrunes.app"

    private let defaults: UserDefaults?

    /// `defaults` nil reads as no goals and keeps none (a group the build cannot open).
    public init(defaults: UserDefaults? = UserDefaults(suiteName: SavingsGoalStore.appGroup)) {
        self.defaults = defaults
    }

    public func load() -> [SavingsGoal] {
        guard let data = defaults?.data(forKey: Self.key),
              let goals = try? JSONCoding.decode([SavingsGoal].self, from: data) else { return [] }
        return goals
    }

    /// Adds a goal; nil (and nothing kept) when it has no name or no amount.
    @discardableResult
    public func add(name: String, coins: Int, now: Date = Date()) -> SavingsGoal? {
        guard let goal = SavingsGoal.make(name: name, coins: coins, now: now) else { return nil }
        save(load() + [goal])
        return goal
    }

    public func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    private func save(_ goals: [SavingsGoal]) {
        guard let defaults else { return }
        if goals.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONCoding.encode(goals) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
