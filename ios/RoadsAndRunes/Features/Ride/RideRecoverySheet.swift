import RoadsAndRunesCore
import SwiftUI

/// Spec §72: an unfinished ride, run or walk. Resume / Save / Discard.
struct RideRecoverySheet: View {
    @Environment(AppContainer.self) private var container
    let state: ActiveRideState

    /// "ride", "run" or "walk", as it was started.
    private var journey: String { LoreCopy.journey(state.activity.flatMap(Activity.init(rawValue:))) }

    var body: some View {
        let formatter = UnitFormatter(units: container.session.units)
        VStack(spacing: Theme.Spacing.lg) {
            SheetHandle()
            ZStack {
                Circle().fill(Theme.Colors.surface)
                Image(systemName: "arrow.counterclockwise").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.Colors.terracotta)
            }
            .frame(width: 72, height: 72)
            Text("You have an unfinished \(journey)").font(Theme.Typography.title).foregroundStyle(Theme.Colors.ink).multilineTextAlignment(.center)
            Text("Started \(state.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatter.distance(meters: state.stats.distanceMeters)) · \(formatter.duration(seconds: state.stats.elapsedSeconds))")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).multilineTextAlignment(.center)
            VStack(spacing: Theme.Spacing.sm) {
                Button("Resume \(journey)") { Task { await container.rideRecorder.resumeRecovered() } }.buttonStyle(.primary)
                Button("Save \(journey)") { Task { await container.rideRecorder.finishRecovered() } }.buttonStyle(.secondaryWide)
                Button("Discard \(journey)") { container.rideRecorder.discardRecovered() }
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
            }
        }
        .padding(Theme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationBackground(Theme.Colors.cream)
        .interactiveDismissDisabled()
    }
}
