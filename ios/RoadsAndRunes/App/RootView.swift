import RoadsAndRunesCore
import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var recorder = container.rideRecorder
        @Bindable var sync = container.sync
        Group {
            switch container.session.state {
            case .loading:
                ProgressView("Loading your world…").tint(Theme.Colors.moss)
            case .signedOut, .needsCharacter:
                OnboardingFlow()
            case .ready:
                MainTabView()
            }
        }
        .fullScreenCover(isPresented: $recorder.isActive) {
            NavigationScreen()
        }
        .sheet(item: $recorder.recoverableRide) { state in
            RideRecoverySheet(state: state)
        }
        .sheet(item: $sync.latestSummary) { summary in
            AdventureSummaryView(summary: summary, units: container.session.units) {
                container.sync.latestSummary = nil
            }
            .interactiveDismissDisabled()
        }
        .tint(Theme.Colors.moss)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            WorldView()
                .tabItem { Label("World", systemImage: "map") }
            QuestsView()
                .tabItem { Label("Quests", systemImage: "scroll") }
            JournalView()
                .tabItem { Label("Journal", systemImage: "book.closed") }
            CharacterView()
                .tabItem { Label("Character", systemImage: "person") }
        }
    }
}

extension AdventureSummary: Identifiable {
    public var id: UUID { ride.id }
}

extension ActiveRideState: Identifiable {
    public var id: UUID { clientRideId }
}
