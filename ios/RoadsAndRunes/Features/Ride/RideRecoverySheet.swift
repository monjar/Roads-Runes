import RoadsAndRunesCore
import SwiftUI

/// Spec §72: "We found an unfinished ride. Resume / Finish / Discard".
struct RideRecoverySheet: View {
    @Environment(AppContainer.self) private var container
    let state: ActiveRideState

    var body: some View {
        let formatter = UnitFormatter(units: container.session.units)
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 48)).foregroundStyle(Theme.Colors.rune)
            Text("We found an unfinished ride").font(Theme.Typography.title)
            Text("Started \(state.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatter.distance(meters: state.stats.distanceMeters)) · \(formatter.duration(seconds: state.stats.elapsedSeconds))")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary).multilineTextAlignment(.center)
            VStack(spacing: Theme.Spacing.sm) {
                Button { Task { await container.rideRecorder.resumeRecovered() } } label: { Text("Resume").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.Colors.moss)
                Button { Task { await container.rideRecorder.finishRecovered() } } label: { Text("Finish and save").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                Button(role: .destructive) { container.rideRecorder.discardRecovered() } label: { Text("Discard").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large).tint(Theme.Colors.ember)
            }
        }
        .padding(Theme.Spacing.lg)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}
