import ActivityKit
import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI
import WidgetKit

/// The journey on the lock screen and in the Dynamic Island: the next turn and
/// how far to it, the distance so far, and the quarry's mark in its ring of
/// health. Nothing to read about the fight; the ring says it.
struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            RideLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(WidgetStyle.cream)
                .activitySystemActionForegroundColor(WidgetStyle.ink)
                .widgetURL(DeepLink.ride.url)
        } dynamicIsland: { context in
            let state = context.state
            let formatter = context.attributes.formatter
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurnBadge(state: state, formatter: formatter, onBlack: true)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let tenths = state.quarryTenthsLeft, state.quarryIcon != nil {
                        QuarryRing(icon: state.quarryIcon, tenthsLeft: tenths, palette: .watch, lineWidth: 3)
                            .frame(width: 52, height: 52)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(RideLines.instruction(state, activity: context.attributes.activity))
                            .font(WidgetStyle.text(15, bold: true, relativeTo: .headline))
                            .foregroundStyle(WidgetStyle.creamOnBlack)
                            .lineLimit(2)
                        Text(RideLines.distanceSoFar(state, formatter: formatter))
                            .font(WidgetStyle.text(13, relativeTo: .caption))
                            .foregroundStyle(WidgetStyle.mutedOnBlack)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                TurnArrow(state: state)
                    .foregroundStyle(WidgetStyle.terracottaLight)
            } compactTrailing: {
                Text(RideLines.compactDistance(state, formatter: formatter))
                    .font(WidgetStyle.text(14, bold: true, relativeTo: .caption))
                    .foregroundStyle(WidgetStyle.creamOnBlack)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } minimal: {
                TurnArrow(state: state)
                    .foregroundStyle(WidgetStyle.terracottaLight)
            }
            .widgetURL(DeepLink.ride.url)
            .keylineTint(WidgetStyle.terracotta)
        }
    }
}

/// The lock screen: the same as the expanded island, on paper.
struct RideLockScreenView: View {
    let attributes: RideActivityAttributes
    let state: RideActivityState
    let isStale: Bool

    var body: some View {
        let formatter = attributes.formatter
        HStack(alignment: .center, spacing: 14) {
            TurnBadge(state: state, formatter: formatter, onBlack: false)
            VStack(alignment: .leading, spacing: 4) {
                if let title = attributes.questTitle, !title.isEmpty {
                    Text(title)
                        .font(WidgetStyle.voice(15, relativeTo: .headline))
                        .foregroundStyle(WidgetStyle.ink)
                        .lineLimit(1)
                }
                Text(RideLines.instruction(state, activity: attributes.activity))
                    .font(WidgetStyle.text(15, bold: true, relativeTo: .headline))
                    .foregroundStyle(WidgetStyle.ink)
                    .lineLimit(2)
                Text(RideLines.distanceSoFar(state, formatter: formatter))
                    .font(WidgetStyle.text(13, relativeTo: .caption))
                    .foregroundStyle(WidgetStyle.muted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let tenths = state.quarryTenthsLeft, state.quarryIcon != nil {
                QuarryRing(icon: state.quarryIcon, tenthsLeft: tenths, palette: .phone, lineWidth: 3)
                    .frame(width: 58, height: 58)
            }
        }
        .padding(16)
        .opacity(isStale ? 0.6 : 1)
    }
}

/// The turn arrow over how far to it, in the ride screen's colours.
struct TurnBadge: View {
    let state: RideActivityState
    let formatter: UnitFormatter
    let onBlack: Bool

    var body: some View {
        VStack(spacing: 2) {
            TurnArrow(state: state)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(onBlack ? WidgetStyle.terracottaLight : WidgetStyle.terracotta)
                .frame(height: 34)
            if let meters = state.distanceToTurnMeters, !state.paused {
                Text(formatter.distance(meters: meters))
                    .font(WidgetStyle.text(14, bold: true, relativeTo: .caption))
                    .foregroundStyle(onBlack ? WidgetStyle.creamOnBlack : WidgetStyle.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(minWidth: 56)
    }
}

struct TurnArrow: View {
    let state: RideActivityState

    var body: some View {
        Image(systemName: state.paused ? "pause.fill" : RideActivityState.symbol(for: state.sign))
            .accessibilityLabel(state.paused ? "Paused" : RideActivityState.phrase(for: state.sign))
    }
}

/// The words beside the arrow: plain, and short enough to take in at a glance.
enum RideLines {
    static func instruction(_ state: RideActivityState, activity: String) -> String {
        if state.paused { return "Paused" }
        if let text = state.instructionText, !text.isEmpty { return text }
        if state.maneuver != nil { return RideActivityState.phrase(for: state.sign) }
        // No route to follow: a free journey.
        let kind = RoadsAndRunesCore.Activity.lenient(activity)
        return "On a \(kind.isUnknown ? "journey" : kind.noun)"
    }

    static func distanceSoFar(_ state: RideActivityState, formatter: UnitFormatter) -> String {
        "Distance \(formatter.distance(meters: state.distanceMeters))"
    }

    /// The island's right-hand side: how far to the turn, else how far so far.
    static func compactDistance(_ state: RideActivityState, formatter: UnitFormatter) -> String {
        if state.paused { return "Paused" }
        return formatter.distance(meters: state.distanceToTurnMeters ?? state.distanceMeters)
    }
}

#Preview("Lock screen", as: .content, using: RideActivityAttributes(activity: "RIDE", questTitle: "The Mill Road")) {
    RideLiveActivity()
} contentStates: {
    RideActivityState(instructionText: "Turn left onto Mill Lane", maneuver: "LEFT", distanceToTurnMeters: 180,
                      distanceMeters: 4_250, quarryIcon: "troll", quarryTenthsLeft: 7)
    RideActivityState(distanceMeters: 4_250, paused: true)
}
