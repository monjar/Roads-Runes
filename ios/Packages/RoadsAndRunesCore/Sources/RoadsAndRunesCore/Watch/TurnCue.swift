import Foundation

/// A tap on the wrist for a turn: once as it comes up, once when it is here.
/// The Watch had a screen for the arrow and nothing that could be felt, so a
/// turn was only known to a rider who was looking.
public enum TurnCue: Hashable, Sendable {
    public enum Side: Hashable, Sendable { case left, right, other }

    /// The turn is coming: time to look for it.
    case approaching(Side)
    /// The turn is here.
    case now(Side)
}

/// Decides when a turn is worth a tap. Each instruction is cued at most twice
/// (approaching, then now); "carry on" and "you have arrived" are not turns.
public struct TurnCueTracker: Hashable, Sendable {
    public static let approachMeters = 150.0
    public static let nowMeters = 35.0

    private var approached: Set<Int> = []
    private var arrived: Set<Int> = []

    public init() {}

    public static func side(of sign: InstructionSign) -> TurnCue.Side? {
        switch sign {
        case .left, .slightLeft, .sharpLeft: return .left
        case .right, .slightRight, .sharpRight: return .right
        case .uTurn, .roundabout: return .other
        case .continue, .finish, .waypoint, .unknown: return nil
        }
    }

    public mutating func update(instruction: Instruction?, distanceMeters: Double?) -> TurnCue? {
        guard let instruction, let distanceMeters, let side = Self.side(of: instruction.sign) else { return nil }
        if distanceMeters <= Self.nowMeters {
            // Joined right at the turn: one cue, the one that matters.
            approached.insert(instruction.index)
            return arrived.insert(instruction.index).inserted ? .now(side) : nil
        }
        if distanceMeters <= Self.approachMeters {
            return approached.insert(instruction.index).inserted ? .approaching(side) : nil
        }
        return nil
    }

    /// A new route numbers its turns from the start again.
    public mutating func reset() {
        approached = []
        arrived = []
    }
}
