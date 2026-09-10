import RoadsAndRunesCore
import SwiftUI

/// Pause / resume / end (design 7a, screens 6–7). Every tap target is a
/// full-width or half-width pill; End asks once.
struct ControlsScreen: View {
    @Environment(WatchContainer.self) private var container
    @Environment(RideStore.self) private var store
    @State private var confirmingEnd = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                if confirmingEnd {
                    endPrompt
                } else {
                    Text(store.isPaused ? "PAUSED" : "RIDING")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(store.isPaused ? WatchTheme.secondary : WatchTheme.sageLight)
                    Text(store.formatter.duration(seconds: store.elapsedSeconds(at: context.date)))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    Text(store.isPaused ? "Paused · still recording" : "Auto-pauses when you stop")
                        .font(.system(size: 12))
                        .foregroundStyle(WatchTheme.tertiary)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Button {
                            container.send(store.isPaused ? .resume : .pause)
                        } label: {
                            Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 20, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                        }
                        .buttonStyle(.plain)
                        .background(WatchTheme.sage, in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityLabel(store.isPaused ? "Resume" : "Pause")
                        Button {
                            confirmingEnd = true
                        } label: {
                            Text("End")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                        }
                        .buttonStyle(.plain)
                        .background(WatchTheme.surface, in: Capsule())
                        .foregroundStyle(WatchTheme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    private var endPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("End ride?")
                .font(.system(size: 20, weight: .semibold))
            Text("\(store.formatter.distance(meters: store.update?.distanceMeters ?? 0)) · saved to Health")
                .font(.system(size: 14))
                .foregroundStyle(WatchTheme.secondary)
            Spacer(minLength: 0)
            Button {
                container.send(.end)
                confirmingEnd = false
            } label: {
                Text("End & save")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .background(WatchTheme.accent, in: Capsule())
            .foregroundStyle(.white)
            Button {
                confirmingEnd = false
            } label: {
                Text("Keep riding")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .background(WatchTheme.surface, in: Capsule())
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
