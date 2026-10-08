import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// A festival's arc on the Quests tab (0.9.0): Spring Festival, Midsummer, Harvest
/// or Midwinter, three steps, and when the festival ends. A missed one comes back
/// next year.
struct SeasonArcCard: View {
    let arc: StoryArc
    var onOpenQuest: (UUID) -> Void = { _ in }

    private var festival: String { SeasonCopy.name(arc.season) ?? arc.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                MarkView(.token(GameIcon.named(SeasonCopy.icon(arc.season), or: .sparkles), ring: .gold))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Festival", color: Theme.Colors.terracottaDeep)
                    Text(arc.title == festival ? festival : "\(festival): \(arc.title)")
                        .font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(arc.completedCount) of \(arc.quests.count)")
                        .font(Theme.Typography.captionStrong.monospacedDigit())
                        .foregroundStyle(arc.isComplete ? Theme.Colors.sageDeep : Theme.Colors.muted)
                    if let ends = arc.endsAt {
                        Text(SeasonCopy.ends(ends)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
                            .accessibilityIdentifier("season.ends")
                    }
                }
            }
            if !arc.description.isEmpty {
                Text(arc.description).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProgressView(value: Double(arc.completedCount), total: Double(max(1, arc.quests.count)))
                .tint(Theme.Colors.terracotta)
                .accessibilityValue("\(arc.completedCount) of \(arc.quests.count)")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(arc.quests) { step in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(step.state))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(step.state == .completed ? Theme.Colors.sageDeep : Theme.Colors.muted)
                            .frame(width: 18)
                        Text(step.title)
                            .font(Theme.Typography.text(14, step.state == .open ? .semibold : .regular))
                            .foregroundStyle(step.state == .locked ? Theme.Colors.muted : Theme.Colors.ink)
                            .strikethrough(step.state == .completed, color: Theme.Colors.muted)
                        Spacer(minLength: 4)
                        if step.state == .open, let questId = step.questId {
                            Button("Open quest") { onOpenQuest(questId) }
                                .font(Theme.Typography.captionStrong)
                                .foregroundStyle(Theme.Colors.terracottaDeep)
                                .accessibilityIdentifier("season.openQuest")
                        }
                    }
                }
            }
            if arc.isComplete {
                Text("\(festival) done! See you at the next festival.")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
            } else if let reward = LoreCopy.arcReward(arc.reward) {
                Text(reward).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
        .padding(16)
        .background(Theme.Colors.terracottaTint.opacity(0.55), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("seasonArc")
    }

    private func symbol(_ state: StoryStep.State) -> String {
        switch state {
        case .completed: return "checkmark.circle.fill"
        case .open: return "circle.circle.fill"
        case .ready: return "circle"
        case .waiting: return "hourglass"
        case .locked, .unknown: return "lock.fill"
        }
    }
}
