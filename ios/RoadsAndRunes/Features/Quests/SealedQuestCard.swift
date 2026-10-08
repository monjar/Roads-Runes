import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// "Sealed quest" on the Quests tab (0.7.3): pick 20, 40 or 90 minutes, the board
/// picks the way, and the goal opens halfway. Each length plans at once and opens
/// the route card with Start.
struct SealedQuestCard: View {
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MarkView(.token(.scroll, ring: .terracotta)).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Pick a time", color: Theme.Colors.terracottaDeep)
                    Text("Sealed quest").font(Theme.Typography.voice(18, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink)
                    Text("The board picks the way. Your goal opens halfway.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                ForEach(SealedQuest.minuteChoices, id: \.self) { minutes in
                    Button { onPick(minutes) } label: {
                        Text("\(minutes) min")
                            .font(Theme.Typography.text(15, .semibold))
                            .foregroundStyle(Theme.Colors.cream)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.Colors.terracotta, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Sealed quest, \(minutes) minutes")
                    .accessibilityIdentifier("sealed.\(minutes)")
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sealedQuestCard")
    }
}

/// A sealed quest's objective as a card may show it: what was done once it is
/// done, else that the goal opens halfway. Away from a ride there is no halfway.
enum SealedQuestCopy {
    static func shown(_ objective: Objective, in quest: Quest, routeFraction: Double? = nil) -> Objective {
        guard SealedQuest.isSealed(quest) else { return objective }
        var shown = objective
        if SealedQuest.isOpen(quest, routeFraction: routeFraction), let goal = SealedQuest.goal(of: quest) {
            shown.title = goal.title
        } else if objective.required {
            shown.title = SealedQuest.shutLine
        }
        return shown
    }
}
