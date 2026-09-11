import SwiftUI

/// Entry to a ride that is not a quest (design 1a, "What kind of ride today?"):
/// the rider describes the ride, the planner answers with three ways to ride
/// it, and every new road still counts. Sits at the top of the Quests tab;
/// the dashed tile marks it as unwritten.
struct CustomAdventureCard: View {
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.Colors.terracotta, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                Image(systemName: "signpost.right.fill")
                    .font(.system(size: compact ? 18 : 24, weight: .bold))
                    .foregroundStyle(Theme.Colors.terracottaDeep)
            }
            .frame(width: compact ? 44 : 64, height: compact ? 44 : 64)
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "Your own adventure", color: Theme.Colors.terracottaDeep)
                Text("Ride somewhere new")
                    .font(compact ? Theme.Typography.cardTitle : Theme.Typography.voice(18, relativeTo: .title3))
                    .foregroundStyle(Theme.Colors.ink)
                Text("Describe the ride · every new road counts")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your own adventure. Ride somewhere new.")
    }
}
