import RoadsAndRunesCore
import SwiftUI

/// Spec §72: "We found an unfinished ride. Resume / Finish / Discard".
struct RideRecoverySheet: View {
    @Environment(AppContainer.self) private var container
    let state: ActiveRideState

    var body: some View {
        let formatter = UnitFormatter(units: container.session.units)
        VStack(spacing: Theme.Spacing.lg) {
            SheetHandle()
            ZStack {
                Circle().fill(Theme.Colors.surface)
                Image(systemName: "arrow.counterclockwise").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.Colors.terracotta)
            }
            .frame(width: 72, height: 72)
            Text("We found an unfinished ride").font(Theme.Typography.title).foregroundStyle(Theme.Colors.ink).multilineTextAlignment(.center)
            Text("Started \(state.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatter.distance(meters: state.stats.distanceMeters)) · \(formatter.duration(seconds: state.stats.elapsedSeconds))")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).multilineTextAlignment(.center)
            VStack(spacing: Theme.Spacing.sm) {
                Button("Resume") { Task { await container.rideRecorder.resumeRecovered() } }.buttonStyle(.primary)
                Button("Finish and save") { Task { await container.rideRecorder.finishRecovered() } }.buttonStyle(.secondaryWide)
                Button("Discard") { container.rideRecorder.discardRecovered() }
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
            }
        }
        .padding(Theme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationBackground(Theme.Colors.cream)
        .interactiveDismissDisabled()
    }
}
