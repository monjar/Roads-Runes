import RoadsAndRunesCore
import SwiftUI

/// "How do you mostly get around?" — the third onboarding step. Runs and walks
/// count as much as rides; the answer only sets the default, and any outing can
/// be planned differently. A rider goes on to set up a bike; feet skip it.
struct ActivitySetupView: View {
    @Environment(AppContainer.self) private var container
    let onDone: (Activity) -> Void
    @State private var selected: Activity = .ride
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "How you move", color: Theme.Colors.sageDeep)
            Text("How do you\nmostly get around?").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
            Text("Runs and walks count as much as rides: the same map, the same quests, sized for your feet. You can choose differently for any outing.")
                .font(Theme.Typography.text(13.5)).foregroundStyle(Theme.Colors.muted).lineSpacing(2)
            ForEach([Activity.ride, .run, .walk], id: \.self) { activity in
                Button {
                    withAnimation(.snappy) { selected = activity }
                } label: {
                    ActivityCard(activity: activity, selected: selected == activity)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("onboarding.activity.\(activity.rawValue.lowercased())")
            }
            Spacer()
            Button {
                saving = true
                Task {
                    await container.session.setDefaultActivity(selected)
                    saving = false
                    onDone(selected)
                }
            } label: { Text(saving ? "Saving…" : "Continue") }
                .buttonStyle(.primary)
                .disabled(saving)
                .accessibilityIdentifier("onboarding.activity.continue")
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
    }
}

struct ActivityCard: View {
    let activity: Activity
    let selected: Bool

    private var line: String {
        switch activity {
        case .run: return "Quests a run long, and monsters that fall to a fast kilometre."
        case .walk: return "Short loops, parks and places worth a wander."
        default: return "The whole map, and the bike that decides which roads."
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(selected ? Theme.Colors.sage : Theme.Colors.cream).frame(width: 56, height: 56)
                Image(systemName: activity.symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(selected ? Theme.Colors.cream : Theme.Colors.ink)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(activity.verb).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    if selected { Eyebrow(text: "Chosen", color: Theme.Colors.sageDeep) }
                }
                Text(line).font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft).lineSpacing(2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(selected ? Theme.Colors.sage : .clear, lineWidth: 2))
    }
}
