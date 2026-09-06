import RoadsAndRunesCore
import SwiftUI
import WatchKit

/// Spec §47: brief full-screen confirmation with a success haptic; returns to
/// navigation automatically, no interaction required.
struct ObjectiveCompleteOverlay: View {
    let event: WatchObjectiveCompleted
    let token: Int
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(WatchTheme.success)
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 46, height: 46)
            Text("OBJECTIVE COMPLETE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color(red: 0.62, green: 0.85, blue: 0.67))
            Text(event.title)
                .font(.system(size: 17, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
            if let xp = event.xp {
                Text("+\(xp) XP")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(WatchTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.06, green: 0.16, blue: 0.09))
        .task(id: token) {
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(for: .seconds(3))
            dismiss()
        }
        .onTapGesture { dismiss() }
    }
}
