import RoadsAndRunesCore
import SwiftUI
import WatchKit

/// Objective complete (design 16a, "full sage"): takes over for ~4 s with the
/// rising-triplet haptic, then returns to the arrow. No tap required.
struct ObjectiveCompleteOverlay: View {
    let event: WatchObjectiveCompleted
    let token: Int
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(WatchTheme.cream)
                Image(systemName: "sparkle")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(WatchTheme.sage)
            }
            .frame(width: 56, height: 56)
            Text("OBJECTIVE COMPLETE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .padding(.top, 6)
            Text(event.title)
                .font(.system(size: 17, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
            Spacer(minLength: 0)
            if let xp = event.xp {
                Text("+\(xp) XP")
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
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
        .onTapGesture { dismiss() }
    }
}
