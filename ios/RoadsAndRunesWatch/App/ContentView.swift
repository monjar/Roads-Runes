import RoadsAndRunesCore
import SwiftUI

struct ContentView: View {
    @Environment(RideStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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

/// Vertical pages (design 7a + 16a): navigation, quest, ride, controls.
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

/// Ride ready (design 7a, screen 1): what is loaded, one sage pill to start.
struct IdleScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("READY")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(WatchTheme.accent)
            Text("Roads & Runes")
                .font(.system(size: 19, weight: .semibold))
            Text("Start a ride on your iPhone")
                .font(.system(size: 14))
                .foregroundStyle(WatchTheme.secondary)
            HStack(spacing: 8) {
                Label(store.phoneReachable ? "iPhone" : "iPhone off", systemImage: store.phoneReachable ? "checkmark" : "xmark")
                Label("Heart", systemImage: "checkmark")
            }
            .font(.system(size: 11, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(store.phoneReachable ? WatchTheme.sageLight : WatchTheme.tertiary)
            .padding(.top, 8)
            Spacer()
            Image(systemName: "bicycle")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(WatchTheme.sage)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
    }
}

/// Native dark watch face (design 7a): terracotta is the instruction and the
/// route, sage is you and success; system type, numbers heavy.
enum WatchTheme {
    static let accent = Color(red: 0.965, green: 0.627, blue: 0.420)      // #f6a06b terracotta on ink
    static let sage = Color(red: 0.478, green: 0.541, blue: 0.369)        // #7a8a5e
    static let sageLight = Color(red: 0.682, green: 0.749, blue: 0.573)   // #aebf92
    static let secondary = Color(red: 0.753, green: 0.714, blue: 0.647)   // #c0b6a5
    static let tertiary = Color(red: 0.510, green: 0.475, blue: 0.416)    // #82796a
    static let surface = Color(red: 0.165, green: 0.165, blue: 0.165)     // #2a2a2a
    static let cream = Color(red: 0.961, green: 0.918, blue: 0.847)       // #f5ead8
    static let heart = Color(red: 1.0, green: 0.561, blue: 0.561)         // #ff8f8f
    static let success = sage
    static let danger = accent
}
