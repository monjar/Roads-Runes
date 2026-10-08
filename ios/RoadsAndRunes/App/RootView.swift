import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container
    /// A player from before the world had a premise sees it once (docs/ROADMAP.md, 0.6.0).
    @State private var showPrologue = false

    var body: some View {
        @Bindable var recorder = container.rideRecorder
        @Bindable var sync = container.sync
        Group {
            if container.session.state == .loading {
                ZStack {
                    Theme.Colors.cream.ignoresSafeArea()
                    ProgressView(LoreCopy.loading).font(Theme.Typography.caption).tint(Theme.Colors.terracotta)
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
        // One cover for the end of a ride: what the phone knows while the server
        // counts, then the reckoning in its place when it comes.
        .fullScreenCover(isPresented: Binding(
            get: { !recorder.isActive && (sync.latestSummary != nil || (sync.pending != nil && !sync.holdingHidden)) },
            set: { shown in if !shown { container.sync.holdingHidden = true } }
        )) {
            if let summary = container.sync.latestSummary {
                AdventureSummaryView(summary: summary, units: container.session.units) {
                    container.sync.dismissReckoning()
                }
            } else if let pending = container.sync.pending {
                RideHoldingView(pending: pending, timedOut: container.sync.pollTimedOut, units: container.session.units) {
                    container.sync.holdingHidden = true
                }
            }
        }
        .fullScreenCover(isPresented: $showPrologue) {
            PrologueView(finish: "Carry on") {
                Prologue.seen = true
                showPrologue = false
            }
        }
        .onChange(of: container.session.state, initial: true) { _, state in
            if state == .ready, !container.session.isOnboarding, !Prologue.seen, !AppContainer.isUITesting {
                showPrologue = true
            }
        }
        // The widgets' snapshot (0.7.3): after Journey's end, when the character
        // moves (a streak kept, a level), and cleared on signing out.
        .onChange(of: container.sync.latestSummary?.ride.id) { _, id in
            if id != nil { WidgetSnapshotWriter.shared.journeyEnded() }
        }
        .onChange(of: WidgetSnapshotWriter.watched(container.session)) { WidgetSnapshotWriter.shared.write() }
        .tint(Theme.Colors.terracotta)
        // Every colour in the app is a fixed hex on cream; there is no dark palette
        // yet (docs/ROADMAP.md, 1.0), so stock forms must not go dark under it.
        .preferredColorScheme(.light)
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

    var icon: GameIcon {
        switch self {
        case .world: return .treasureMap
        case .quests: return .scroll
        case .journal: return .openBook
        case .character: return .wizardFace
        }
    }
}

struct MainTabView: View {
    @Environment(AppContainer.self) private var container
    @State private var tab: AppTab = .world
    /// A quest a World marker pointed at, for the Quests tab to open.
    @State private var questToOpen: UUID?
    @State private var tabBar = TabBarVisibility()

    init() {
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        TabView(selection: $tab) {
            WorldView(
                onOpenCharacter: { withAnimation(.snappy(duration: 0.25)) { tab = .character } },
                onOpenQuests: { quest in
                    questToOpen = quest
                    withAnimation(.snappy(duration: 0.25)) { tab = .quests }
                }
            )
            .tag(AppTab.world).toolbar(.hidden, for: .tabBar)
            QuestsView(openQuest: $questToOpen).tag(AppTab.quests).toolbar(.hidden, for: .tabBar)
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
        // A widget's or a Shortcut's link to a tab (0.7.3), once the tabs are up.
        .onChange(of: DeepLinkInbox.shared.destination, initial: true) {
            guard let link = DeepLinkInbox.shared.takeDestination(), let target = AppTab(link: link) else { return }
            withAnimation(.snappy(duration: 0.25)) { tab = target }
        }
        // The first look at the bag after 0.7.2 pays the levels already reached: said once.
        .task { await container.session.refreshInventory() }
        .sheet(isPresented: Binding(
            get: { !container.session.levelRewardsToShow.isEmpty && !container.rideRecorder.isActive },
            set: { shown in if !shown { container.session.levelRewardsToShow = [] } }
        )) {
            LevelRewardsSheet(rewards: container.session.levelRewardsToShow) { container.session.levelRewardsToShow = [] }
        }
        // A quick start (0.7.3): the route card with Start, from Siri, a widget, the board or the Watch.
        .sheet(isPresented: Binding(
            get: { QuickStartCoordinator.shared.isPresented && !container.rideRecorder.isActive },
            set: { shown in if !shown, !QuickStartCoordinator.shared.isStarting { QuickStartCoordinator.shared.dismiss() } }
        )) {
            QuickStartSheet(coordinator: QuickStartCoordinator.shared)
        }
    }
}

/// The floating ink pill; the active tab is a terracotta pill inside it.
struct FloatingTabBar: View {
    @Environment(AppContainer.self) private var container
    @Binding var selected: AppTab

    /// A skill point waiting and a skill to spend it on: the Character tab says so.
    private var skillWaiting: Bool {
        guard let character = container.session.character else { return false }
        return character.unspentAbilityPoints > 0 && character.abilities.contains(where: \.canUnlock)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selected = tab }
                } label: {
                    VStack(spacing: 3) {
                        IconShape(tab.icon).frame(width: 22, height: 22)
                            .overlay(alignment: .topTrailing) {
                                if tab == .character, skillWaiting {
                                    Circle().fill(Theme.Colors.gold).frame(width: 9, height: 9)
                                        .offset(x: 4, y: -2)
                                        .accessibilityLabel("A skill point to spend")
                                }
                            }
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
