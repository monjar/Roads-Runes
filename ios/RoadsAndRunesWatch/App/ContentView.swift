import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI
import WatchKit

struct ContentView: View {
    @Environment(RideStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if store.hasRoute || store.isRiding {
                RidePages()
            } else if store.planning != nil {
                PlanningScreen()
            } else if let end = store.journeyEnd {
                JourneyEndCard(end: end, token: store.journeyEndToken) {
                    store.dismissJourneyEnd()
                }
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
        .onChange(of: store.turnCueToken) { _, _ in
            if let cue = store.turnCue { TurnHaptics.play(cue) }
        }
    }
}

/// A turn, felt: two soft taps as it comes up; when it is here, one for a right
/// turn and two for a left (design 7a), so the wrist says which way without a look.
/// Every tap is named in Core (`WristTap`), where a test keeps a fight's taps
/// apart from these.
enum TurnHaptics {
    static func play(_ cue: TurnCue) {
        switch cue {
        case .approaching:
            tap(.click)
            later(0.25) { tap(.click) }
        case .now(let side):
            tap(side == .left ? .directionDown : .directionUp)
            if side == .left { later(0.45) { tap(.directionDown) } }
        }
    }

    /// A fight beat: one tap, never one a turn uses.
    static func play(_ beat: FightBeat) {
        tap(beat.tap)
    }

    /// Journey's end has come: the journey is over, so no turn is near to be
    /// mistaken for it, and it takes the game's own success tap.
    static func journeyEnded() {
        tap(.success)
    }

    static func tap(_ tap: WristTap) {
        let device = WKInterfaceDevice.current()
        switch tap {
        case .click: device.play(.click)
        case .directionUp: device.play(.directionUp)
        case .directionDown: device.play(.directionDown)
        case .start: device.play(.start)
        case .success: device.play(.success)
        case .failure: device.play(.failure)
        }
    }

    private static func later(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            body()
        }
    }
}

/// Vertical pages (design 7a + 16a): navigation, the map, quest, ride, controls.
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
            // Directions answer "what do I do next"; the map answers "where am I".
            // Always-On keeps both (0.7.3): the map dims to the route, the rider and
            // the next turn, and moves only now and then.
            MapScreen()
            QuestScreen()
            StatsScreen()
            ControlsScreen()
        }
        .tabViewStyle(.verticalPage)
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
