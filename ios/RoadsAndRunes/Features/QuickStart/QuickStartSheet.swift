import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The route card a quick start opens on (0.7.3): what was asked for, the route
/// drawn, and Start. While it plans it says so; when it cannot, it says why in
/// plain words and hands over to the planner.
struct QuickStartSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let coordinator: QuickStartCoordinator
    /// "Send to Garmin": the route as a FIT course, through the share sheet.
    @State private var export: ExportRequest?

    private var units: Units { container.session.units }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Colors.cream.ignoresSafeArea()
            switch coordinator.phase {
            case .failed(let line):
                // The plain error, then the planner to do it by hand.
                RoutePlannerView(quest: nil)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ErrorLine(text: line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .accessibilityIdentifier("quickStart.error")
                    }
            case .ready:
                if let plan = coordinator.plan { ready(plan) }
            case .planning, .idle:
                planning
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(item: $export) { ExportFileSheet(request: $0) }
    }

    // MARK: Planning

    private var planning: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text(heading).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
            HStack(spacing: 10) {
                ProgressView().tint(Theme.Colors.terracotta)
                Text("Planning…").font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.inkSoft)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("quickStart.planning")
            if case .sealed = coordinator.request {
                Text("The board picked the way. Your goal opens halfway.")
                    .font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Ready

    @ViewBuilder
    private func ready(_ plan: QuickStartCoordinator.Plan) -> some View {
        let sealed = SealedQuest.isSealed(plan.quest)
        // A sealed route's stops could name its goal: the card leaves them off.
        let shown = sealed ? Self.withoutStops(plan.route) : plan.route
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                header
                Text(plan.quest?.title ?? plan.title ?? heading)
                    .font(Theme.Typography.voice(30, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(3)
                if let quest = plan.quest {
                    Text(quest.narrative.hook ?? quest.description)
                        .font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    if sealed {
                        HStack(spacing: 8) {
                            MarkView(.icon(.scroll, spot: .terracotta)).frame(width: 18, height: 18)
                            Text(SealedQuest.shutLine).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("quickStart.sealedGoal")
                    }
                }
                RouteCard(route: shown, selected: true, units: units, badge: badge)
                    .accessibilityIdentifier("quickStart.route")
                RouteDetailPanel(route: shown, units: units, camera: MapCamera(fit: shown.path, padding: UIEdgeInsets(top: 26, left: 22, bottom: 46, right: 22)))
                // Never a sealed quest's route: it would give the goal away.
                if !sealed, !container.rideRecorder.isActive {
                    Button { export = .garminCourse(routeId: plan.route.id) } label: {
                        Label("Send to Garmin", systemImage: "paperplane")
                    }
                    .buttonStyle(.surfacePill)
                    .accessibilityIdentifier("quickStart.garmin")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 130)
        }
        VStack(spacing: 8) {
            Button {
                Task { _ = await coordinator.startRide() }
            } label: {
                HStack(spacing: 10) {
                    if coordinator.isStarting { ProgressView().tint(Theme.Colors.cream) } else { Image(systemName: "play.fill") }
                    Text(coordinator.isStarting ? "Downloading route…" : "Start \(plan.activity.noun)")
                }
            }
            .buttonStyle(.primary)
            .disabled(coordinator.isStarting || container.rideRecorder.isActive)
            .accessibilityIdentifier("quickStart.start")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [Theme.Colors.cream.opacity(0), Theme.Colors.cream], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            IconCircleButton(symbol: "xmark", background: Theme.Colors.surface) { dismiss() }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("quickStart.close")
            Spacer()
            Eyebrow(text: eyebrow, color: Theme.Colors.terracottaDeep)
        }
    }

    /// What was asked for, in a word or two.
    private var eyebrow: String {
        switch coordinator.request {
        case .loop(let minutes, _): return "Quick loop · \(minutes) min"
        case .bounty: return "Today's bounty"
        case .sealed(let minutes): return "Sealed quest · \(minutes) min"
        case .quest: return "Quest"
        case nil: return "Quick start"
        }
    }

    private var heading: String {
        switch coordinator.request {
        case .loop(let minutes, let activity): return "A \(minutes)-minute \(activity == .unknown ? "loop" : activity.noun)"
        case .bounty: return "Off to the bounty"
        case .sealed: return "Sealed quest"
        case .quest, nil: return "Your route"
        }
    }

    private var badge: String? {
        switch coordinator.request {
        case .sealed: return "Sealed quest"
        case .quest: return "Quest route"
        case .bounty: return "Bounty"
        case .loop, nil: return nil
        }
    }

    static func withoutStops(_ route: RouteOption) -> RouteOption {
        var route = route
        route.pois = []
        return route
    }
}
