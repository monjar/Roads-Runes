import RoadsAndRunesCore
import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        @Bindable var recorder = container.rideRecorder
        @Bindable var sync = container.sync
        Group {
            if container.session.state == .loading {
                ZStack {
                    Theme.Colors.cream.ignoresSafeArea()
                    ProgressView("Loading your world…").font(Theme.Typography.caption).tint(Theme.Colors.terracotta)
                }
            } else if container.session.state != .ready || container.session.isOnboarding {
                // One branch for every onboarding state, so its step survives the character
                // being created (which makes the session ready before the bike and location steps).
                OnboardingFlow()
            } else {
                MainTabView()
            }
        }
        .fullScreenCover(isPresented: $recorder.isActive) {
            NavigationScreen()
        }
        .sheet(item: $recorder.recoverableRide) { state in
            RideRecoverySheet(state: state)
        }
        .fullScreenCover(item: $sync.latestSummary) { summary in
            AdventureSummaryView(summary: summary, units: container.session.units) {
                container.sync.latestSummary = nil
            }
        }
        .tint(Theme.Colors.terracotta)
    }
}

/// World · Quests · Journal · Character. Ride is a mode, not a tab.
enum AppTab: Int, CaseIterable, Identifiable {
    case world, quests, journal, character

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .world: return "World"
        case .quests: return "Quests"
        case .journal: return "Journal"
        case .character: return "Character"
        }
    }

    var symbol: String {
        switch self {
        case .world: return "globe"
        case .quests: return "sparkle"
        case .journal: return "book.closed"
        case .character: return "shield"
        }
    }
}

struct MainTabView: View {
    @State private var tab: AppTab = .world
    @State private var tabBar = TabBarVisibility()

    init() {
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        TabView(selection: $tab) {
            WorldView { withAnimation(.snappy(duration: 0.25)) { tab = .character } }.tag(AppTab.world).toolbar(.hidden, for: .tabBar)
            QuestsView().tag(AppTab.quests).toolbar(.hidden, for: .tabBar)
            JournalView().tag(AppTab.journal).toolbar(.hidden, for: .tabBar)
            CharacterView().tag(AppTab.character).toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !tabBar.isHidden {
                FloatingTabBar(selected: $tab)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: tabBar.isHidden)
        .background(Theme.Colors.cream.ignoresSafeArea())
        .environment(tabBar)
    }
}

/// The floating ink pill; the active tab is a terracotta pill inside it.
struct FloatingTabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selected = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 18, weight: .bold))
                        Text(tab.title).font(Theme.Typography.tab)
                    }
                    .foregroundStyle(selected == tab ? Theme.Colors.cream : Theme.Colors.line)
                    .padding(.horizontal, selected == tab ? 18 : 12)
                    .padding(.vertical, 8)
                    .background(selected == tab ? Theme.Colors.terracotta : .clear, in: Capsule())
                    // The whole slot takes the tap, not only the pill.
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Layout.tabBarHeight)
        .background(Theme.Colors.ink, in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 16, y: 12)
    }
}

extension AdventureSummary: @retroactive Identifiable {
    public var id: UUID { ride.id }
}

extension ActiveRideState: @retroactive Identifiable {
    public var id: UUID { clientRideId }
}
