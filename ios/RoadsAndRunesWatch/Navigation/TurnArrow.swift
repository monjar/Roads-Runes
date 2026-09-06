import RoadsAndRunesCore
import SwiftUI

/// Maps an instruction sign to a glyph and a direction word.
struct TurnArrow: View {
    let sign: InstructionSign
    var size: CGFloat = 44
    var color: Color = WatchTheme.accent

    var body: some View {
        Image(systemName: TurnArrow.symbol(for: sign))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .accessibilityLabel(TurnArrow.word(for: sign))
    }

    static func symbol(for sign: InstructionSign) -> String {
        switch sign {
        case .continue: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.turn.down.left"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.turn.down.right"
        case .uTurn: return "arrow.uturn.left"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .finish: return "flag.checkered"
        case .waypoint: return "mappin"
        case .unknown: return "arrow.up"
        }
    }

    static func word(for sign: InstructionSign) -> String {
        switch sign {
        case .continue: return "STRAIGHT"
        case .slightLeft: return "SLIGHT LEFT"
        case .left: return "LEFT"
        case .sharpLeft: return "SHARP LEFT"
        case .slightRight: return "SLIGHT RIGHT"
        case .right: return "RIGHT"
        case .sharpRight: return "SHARP RIGHT"
        case .uTurn: return "U-TURN"
        case .roundabout: return "ROUNDABOUT"
        case .finish: return "FINISH"
        case .waypoint: return "WAYPOINT"
        case .unknown: return "CONTINUE"
        }
    }
}
