import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The idle face between journeys. With Next up from the phone (0.7.3): the
/// streak, today's bounty and how far, the quests taken, and a journey to start
/// from the wrist. Without it (an older phone, or before the phone first speaks):
/// the 0.7.2 face that says to start on the iPhone.
struct IdleScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        if let idle = store.idle {
            NextUpScreen(idle: idle)
        } else {
            ReadyScreen()
        }
    }
}

/// Next up (0.7.3). Every button asks the phone to plan and start; with no phone
/// to ask, it says to open the app on the iPhone instead.
struct NextUpScreen: View {
    @Environment(WatchContainer.self) private var container
    @Environment(RideStore.self) private var store
    let idle: WatchIdleInfo

    static let loopMinutes = [20, 40]

    var body: some View {
        // Read once a minute at most: the streak and the bounty change by the day and the hour.
        TimelineView(.everyMinute) { context in
            content(at: context.date)
        }
    }

    private var activity: Activity { idle.activityKind ?? .ride }

    private func content(at now: Date) -> some View {
        let days = idle.streak(at: now)
        let kept = idle.streakKept(at: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("NEXT UP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(WatchTheme.accent)
                row(mark: .icon(.campfire, spot: kept ? .gold : nil),
                    title: days > 0 ? LoreCopy.streak(days) : "Start a streak",
                    detail: kept ? "Kept today" : "\(activity.verb) today to keep it")
                if let pledge = idle.pledge {
                    row(mark: .token(WristMarks.icon(pledge.icon, otherwise: .flag)), title: "Today's pledge", detail: pledge.targetName)
                }
                if !store.phoneReachable {
                    Text("Open the app on your iPhone to start.")
                        .font(.system(size: 13))
                        .foregroundStyle(WatchTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("watch.nextUp.unreachable")
                }
                if let bounty = idle.liveBounty(at: now) {
                    row(mark: .token(WristMarks.icon(bounty.icon, species: bounty.speciesId, otherwise: .dragonHead), ring: .gold),
                        title: bounty.name, detail: bountyLine(bounty), size: 32)
                    if store.phoneReachable {
                        WatchPill(title: "\(activity.verb) to bounty", identifier: "watch.nextUp.bounty") {
                            container.requestStart(.bounty(activity: activity))
                        }
                    }
                }
                if !idle.quests.isEmpty {
                    section("Quests")
                    ForEach(idle.quests) { quest in
                        row(mark: .token(WristMarks.icon(quest.icon, otherwise: .scroll)), title: quest.title,
                            detail: quest.distanceMeters.map { store.formatter.distance(meters: $0) })
                        if store.phoneReachable {
                            WatchPill(title: "Start quest", identifier: "watch.nextUp.quest", style: .quiet) {
                                container.requestStart(.quest(id: quest.id))
                            }
                            .accessibilityLabel("Start \(quest.title)")
                        }
                    }
                }
                if store.phoneReachable {
                    section("Quick loop")
                    HStack(spacing: 6) {
                        ForEach(Self.loopMinutes, id: \.self) { minutes in
                            WatchPill(title: "\(minutes) min", identifier: "watch.nextUp.loop\(minutes)", style: .quiet) {
                                container.requestStart(.loop(minutes: minutes, activity: activity))
                            }
                            .accessibilityLabel("\(minutes)-minute loop")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        }
    }

    /// "Bounty · 2.4 km".
    private func bountyLine(_ bounty: WatchIdleInfo.Bounty) -> String {
        guard let meters = bounty.distanceMeters else { return "Bounty" }
        return "Bounty · \(store.formatter.distance(meters: meters))"
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(WatchTheme.sageLight)
            .padding(.top, 4)
    }

    private func row(mark: Mark, title: String, detail: String?, size: CGFloat = 24) -> some View {
        HStack(spacing: 8) {
            MarkView(mark, palette: .watch)
                .frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(WatchTheme.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// While the phone plans what was asked for on the wrist, and when it could not.
struct PlanningScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            if store.planningFailed {
                Text("Couldn't plan. Try on your iPhone.")
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("watch.planning.failed")
                WatchPill(title: LoreCopy.done, identifier: "watch.planning.done") {
                    store.dismissPlanning()
                }
            } else {
                ProgressView()
                Text("Planning…")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WatchTheme.cream)
                    .accessibilityIdentifier("watch.planning")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
    }
}

/// A full-width pill: sage for the main thing, quiet for the rest.
struct WatchPill: View {
    enum Style { case main, quiet }

    let title: String
    let identifier: String
    var style: Style = .main
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(style == .main ? WatchTheme.sage : WatchTheme.surface, in: Capsule())
        .foregroundStyle(style == .main ? .white : WatchTheme.cream)
        .accessibilityIdentifier(identifier)
    }
}

/// Ride ready (design 7a, screen 1): what is loaded, and where to start.
struct ReadyScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("READY")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(WatchTheme.accent)
            Text("Roads & Runes")
                .font(.system(size: 19, weight: .semibold))
            Text("Start a journey on your iPhone")
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
            IconShape(.cycling)
                .foregroundStyle(WatchTheme.sage)
                .frame(width: 34, height: 34)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
    }
}
