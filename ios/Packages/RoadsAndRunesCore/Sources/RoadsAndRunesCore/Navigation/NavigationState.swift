import Foundation

/// Navigation session states (PRODUCT_SPEC §33–36).
public enum NavigationState: String, Codable, CaseIterable, Hashable, Sendable {
    case preparing = "PREPARING"
    case ready = "READY"
    case active = "ACTIVE"
    case paused = "PAUSED"
    case offRoute = "OFF_ROUTE"
    case rerouting = "REROUTING"
    case finishing = "FINISHING"
    case completed = "COMPLETED"
    case cancelled = "CANCELLED"
    /// Restored from a persisted session after a crash; the user chooses Resume / Finish / Discard.
    case recovery = "RECOVERY"

    public var isTerminal: Bool { self == .completed || self == .cancelled }

    /// Whether GPS recording should be running in this state.
    public var isRecording: Bool {
        switch self {
        case .active, .offRoute, .rerouting: return true
        default: return false
        }
    }

    public var allowedTransitions: Set<NavigationState> {
        switch self {
        case .preparing: return [.ready, .cancelled]
        case .ready: return [.active, .cancelled]
        case .active: return [.paused, .offRoute, .finishing, .cancelled]
        case .paused: return [.active, .finishing, .cancelled]
        case .offRoute: return [.active, .rerouting, .paused, .finishing, .cancelled]
        case .rerouting: return [.active, .offRoute, .cancelled]
        case .finishing: return [.completed, .cancelled]
        case .recovery: return [.active, .paused, .finishing, .cancelled]
        case .completed, .cancelled: return []
        }
    }

    public func canTransition(to next: NavigationState) -> Bool {
        allowedTransitions.contains(next)
    }
}

public struct NavigationTransitionError: Error, Hashable, Sendable, CustomStringConvertible {
    public let from: NavigationState
    public let to: NavigationState

    public init(from: NavigationState, to: NavigationState) {
        self.from = from
        self.to = to
    }

    public var description: String {
        "Illegal navigation transition \(from.rawValue) -> \(to.rawValue)"
    }
}

/// Value-semantics state machine enforcing the legal transitions.
public struct NavigationStateMachine: Hashable, Sendable {
    public private(set) var state: NavigationState
    public private(set) var previousState: NavigationState?
    public private(set) var lastTransitionAt: Date?

    public init(state: NavigationState = .preparing) {
        self.state = state
    }

    public func canTransition(to next: NavigationState) -> Bool {
        state.canTransition(to: next)
    }

    /// Moves to `next`, throwing `NavigationTransitionError` when the edge is not allowed.
    public mutating func transition(to next: NavigationState, at date: Date = Date()) throws {
        guard state.canTransition(to: next) else {
            throw NavigationTransitionError(from: state, to: next)
        }
        previousState = state
        state = next
        lastTransitionAt = date
    }

    /// Attempts the transition and reports whether it happened.
    @discardableResult
    public mutating func transitionIfPossible(to next: NavigationState, at date: Date = Date()) -> Bool {
        guard state.canTransition(to: next) else { return false }
        previousState = state
        state = next
        lastTransitionAt = date
        return true
    }
}
