import RoadsAndRunesCore
import SwiftUI

/// Always-On variant (design 7a, screen 10): no seconds, thinner weights, 1 Hz,
/// the next turn still readable.
struct AlwaysOnNavigationScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(spacing: 4) {
            if let instruction = store.currentInstruction {
                TurnArrow(sign: instruction.sign, size: 36, color: .white.opacity(0.7))
                Text(store.formatter.distance(meters: store.currentDistanceToInstruction ?? instruction.distanceMeters))
                    .font(.system(size: 42, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(TurnArrow.word(for: instruction.sign))
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                if let speed = store.update?.speedMps {
                    Text("\(Int(store.formatter.speedValue(metersPerSecond: speed).rounded())) \(store.formatter.speedUnitLabel)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                Text("Roads & Runes")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
    }
}
