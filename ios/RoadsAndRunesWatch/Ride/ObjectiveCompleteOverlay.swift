import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI
import WatchKit

/// Objective complete (design 16a, "full sage"): takes over for ~4 s with the
/// rising-triplet haptic, then returns to the arrow. No tap required.
struct ObjectiveCompleteOverlay: View {
    let event: WatchObjectiveCompleted
    let token: Int
    let dismiss: () -> Void

    private var icon: GameIcon {
        switch event.outcome {
        case "GONE": return .sword
        case "OPENED": return .openChest
        case "FOUND": return .runeStone
        default: return .flag
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            // What happened, as the phone draws it: a creature beaten, a chest opened, a find.
            MarkView(.token(icon), palette: .watch)
                .frame(width: 56, height: 56)
            // GONE, OPENED, FOUND or DONE; an older phone sends none.
            Text(event.outcome ?? "DONE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .padding(.top, 6)
            Text(event.title)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
            if let detail = event.detail {
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            if let xp = event.xp {
                Text("+\(xp) XP")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            } else if let coins = event.coins, coins > 0 {
                Text(LoreCopy.earned(coins))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(WatchTheme.sage)
        .ignoresSafeArea()
        .task(id: token) {
            TurnHaptics.tap(.success)
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
        .onTapGesture { dismiss() }
    }
}
