import RoadsAndRunesCore
import SwiftUI

struct ContentView: View {
    @Environment(RideStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ZStack {
            if store.hasRoute || store.isRiding {
                RidePages()
            } else {
                IdleScreen()
            }
            if let objective = store.pendingObjective {
                ObjectiveCompleteOverlay(event: objective, token: store.objectiveToken) {
                    store.clearObjective()
                }
                .transition(.opacity)
            }
        }
        .animation(isLuminanceReduced ? nil : .easeInOut(duration: 0.2), value: store.pendingObjective)
    }
}

/// Vertical pages: navigation, quest, stats, controls (spec §44–46).
struct RidePages: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TabView {
            Group {
                if isLuminanceReduced {
                    AlwaysOnNavigationScreen()
                } else {
                    NavigationScreen()
                }
            }
            QuestScreen()
            StatsScreen()
            ControlsScreen()
        }
        .tabViewStyle(.verticalPage)
    }
}

struct IdleScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bicycle")
                .font(.system(size: 34))
                .foregroundStyle(WatchTheme.accent)
            Text("Roads & Runes")
                .font(.headline)
            Text("Start a ride on your iPhone")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !store.phoneReachable {
                Label("iPhone not reachable", systemImage: "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

enum WatchTheme {
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.20)
    static let success = Color(red: 0.24, green: 0.44, blue: 0.30)
    static let danger = Color(red: 0.76, green: 0.29, blue: 0.20)
}
