import RoadsAndRunesCore
import SwiftUI

/// Pause / resume / end. Large, glove-friendly targets; end asks once.
struct ControlsScreen: View {
    @Environment(WatchContainer.self) private var container
    @Environment(RideStore.self) private var store
    @State private var confirmingEnd = false

    var body: some View {
        VStack(spacing: 12) {
            Button {
                container.send(store.isPaused ? .resume : .pause)
            } label: {
                Label(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(WatchTheme.accent)
            .foregroundStyle(.black)

            Button(role: .destructive) {
                confirmingEnd = true
            } label: {
                Label("End ride", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(WatchTheme.danger)
        }
        .padding()
        .confirmationDialog("End this ride?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End ride", role: .destructive) { container.send(.end) }
            Button("Keep riding", role: .cancel) {}
        } message: {
            Text("Your iPhone will finish and upload the adventure.")
        }
    }
}
