import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// "Pledge for today" in the morning, "Pledge for tomorrow" in the evening, on a
/// creature card and a quest card (0.7.3). Pledged already, it says so and can be
/// taken back. Nothing at all with the `pledge` flag off, or in the afternoon.
struct PledgeButton: View {
    @Environment(AppContainer.self) private var container
    let kind: PledgeTargetKind
    let targetId: UUID
    let targetName: String
    var mark: Mark = .icon(.flag, spot: .terracotta)
    @State private var window: PledgeWindow?
    @State private var asking = false

    private var store: PledgeStore { container.pledges }

    var body: some View {
        Group {
            if !store.isOn {
                EmptyView()
            } else if let pledge = store.open(for: targetId) {
                pledged(pledge)
            } else if let window {
                Button { asking = true } label: {
                    HStack(spacing: 8) {
                        MarkView(.icon(.flag, spot: .terracotta)).frame(width: 18, height: 18)
                        Text(window.buttonTitle)
                    }
                }
                .buttonStyle(.secondaryWide)
                .accessibilityIdentifier("pledge.open")
                .sheet(isPresented: $asking) {
                    PledgeSheet(kind: kind, targetId: targetId, targetName: targetName, mark: mark, window: window)
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .task(id: targetId) {
            window = PledgeWindow.current()
            await store.refresh()
        }
    }

    private func pledged(_ pledge: Pledge) -> some View {
        HStack(spacing: 10) {
            MarkView(.icon(.flag, spot: .sage)).frame(width: 18, height: 18)
            Text(Self.pledgedLine(pledge))
                .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
            Spacer(minLength: 6)
            Button("Cancel pledge") { Task { await store.cancel(pledge) } }
                .buttonStyle(.surfacePill)
                .disabled(store.busy)
                .accessibilityIdentifier("pledge.cancel")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pledge.pledged")
    }

    /// "Pledged for today" / "Pledged for tomorrow", with the reminder's time.
    static func pledgedLine(_ pledge: Pledge, today: String = PledgeWindow.dayString(Date())) -> String {
        let when = pledge.day == today ? "today" : "tomorrow"
        guard let time = pledge.remindAt else { return "Pledged for \(when)" }
        return "Pledged for \(when) · reminder at \(time)"
    }
}

/// What a pledge is and one reminder's time, then "Pledge it".
struct PledgeSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let kind: PledgeTargetKind
    let targetId: UUID
    let targetName: String
    let mark: Mark
    let window: PledgeWindow
    @State private var remind = true
    @State private var remindAt = Date()

    private var store: PledgeStore { container.pledges }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Eyebrow(text: window.buttonTitle, color: Theme.Colors.terracottaDeep)
                Spacer()
                IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34) { dismiss() }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("pledge.close")
            }
            HStack(spacing: 12) {
                MarkView(mark).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(targetName).font(Theme.Typography.voice(22, relativeTo: .title2)).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                    Text(window == .today ? "You'll go out for it today." : "You'll go out for it tomorrow.")
                        .font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
                }
            }
            Text("One pledge a day. Keep it and Journey's end says so. If plans change, nothing is lost.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let other = store.existing(in: window), other.targetId != targetId {
                Text("This takes the place of your pledge for \(other.targetName).")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                    .accessibilityIdentifier("pledge.replaces")
            }
            Toggle(isOn: $remind) {
                Text("Remind me").font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
            }
            .tint(Theme.Colors.sage)
            .accessibilityIdentifier("pledge.remind")
            if remind {
                DatePicker("Reminder time", selection: $remindAt, displayedComponents: .hourAndMinute)
                    .font(Theme.Typography.text(15))
                    .accessibilityIdentifier("pledge.time")
                if !container.nudges.isEnabled {
                    Text("Reminders are off in Settings, so this one won't be sent.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
            }
            if let error = store.error { ErrorLine(text: error) }
            Spacer(minLength: 0)
            Button {
                Task {
                    // Only the hour and minute are sent: the reminder is on the pledged day.
                    if await store.pledge(kind, id: targetId, window: window, remindAt: remind ? remindAt : nil) { dismiss() }
                }
            } label: {
                ZStack {
                    Text("Pledge it").opacity(store.busy ? 0 : 1)
                    if store.busy { ProgressView().tint(Theme.Colors.cream) }
                }
            }
            .buttonStyle(.primary)
            .disabled(store.busy)
            .accessibilityIdentifier("pledge.confirm")
        }
        .padding(22)
        .background(Theme.Colors.cream.ignoresSafeArea())
        .onAppear {
            store.error = nil
            remindAt = Self.defaultTime(for: window)
        }
    }

    /// Eight in the morning for tomorrow; for today, two hours on, by nine at night.
    static func defaultTime(for window: PledgeWindow, now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch window {
        case .tomorrow:
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        case .today:
            let later = calendar.date(byAdding: .hour, value: 2, to: now) ?? now
            let hour = min(21, calendar.component(.hour, from: later))
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? later
        }
    }
}

/// Today's pledge as a row under Next up on the World map.
struct PledgeRow: View {
    let pledge: Pledge

    var body: some View {
        HStack(spacing: 10) {
            MarkView(.icon(GameIcon.named(pledge.icon, or: pledge.targetKind == .quest ? .scroll : .flag), spot: .terracotta))
                .frame(width: 22, height: 22)
            (Text("Pledged today: ").foregroundStyle(Theme.Colors.muted) + Text(pledge.targetName).foregroundStyle(Theme.Colors.ink))
                .font(Theme.Typography.text(13, .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let time = pledge.remindAt {
                Text(time).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nextUp.pledge")
    }
}

/// Journey's end when the journey kept today's pledge, with the thing's mark.
struct PledgeKeptLine: View {
    let kept: PledgeKept

    var body: some View {
        HStack(spacing: 12) {
            MarkView(.token(GameIcon.named(kept.icon, or: .flag), ring: .sage)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(kept.shownLine).font(Theme.Typography.voice(18, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink)
                if let name = kept.targetName {
                    Text("Pledge kept: \(name)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.Colors.sageTint, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary.pledge")
    }
}
