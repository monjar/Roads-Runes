import RoadsAndRunesCore
import SwiftUI

/// Always-On variant (spec §48): dimmed, no animation, next turn still readable.
struct AlwaysOnNavigationScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(spacing: 6) {
            if let instruction = store.currentInstruction {
                TurnArrow(sign: instruction.sign, size: 36, color: .gray)
                Text(store.formatter.distance(meters: store.currentDistanceToInstruction ?? instruction.distanceMeters))
                    .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(instruction.streetName.isEmpty ? instruction.text : instruction.streetName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
            } else {
                Text("Roads & Runes")
                    .font(.footnote)
                    .foregroundStyle(.gray)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
