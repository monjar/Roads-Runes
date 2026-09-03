import RoadsAndRunesCore
import SwiftUI

struct QuestCard: View {
    let quest: Quest
    var compact = false
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quest.title).font(Theme.Typography.heading)
                    Text(quest.questType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                DifficultyChip(difficulty: quest.difficulty.rawValue)
            }
            if !compact {
                Text(quest.description).font(Theme.Typography.body).lineLimit(3)
            }
            HStack(spacing: Theme.Spacing.md) {
                StatChip(icon: "point.topleft.down.to.point.bottomright.curvepath", text: UnitFormatter.distance(meters: quest.recommendedDistanceKm * 1000, units: units))
                StatChip(icon: "clock", text: UnitFormatter.duration(seconds: quest.estimatedDurationMinutes * 60))
                StatChip(icon: "sparkles", text: "\(quest.baseXP) XP")
                if quest.status != .available {
                    Spacer()
                    Text(quest.status.rawValue.capitalized).font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.Colors.rune)
                }
            }
        }
        .card()
    }
}

struct ObjectiveRow: View {
    let objective: Objective
    var distanceMeters: Double? = nil
    let units: Units

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: objective.status == .completed ? "checkmark.circle.fill" : (objective.required ? "circle" : "circle.dashed"))
                .foregroundStyle(objective.status == .completed ? Theme.Colors.moss : Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(objective.title).font(Theme.Typography.body)
                    .strikethrough(objective.status == .completed, color: Theme.Colors.textSecondary)
                if let progress = progressText {
                    Text(progress).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            if let distanceMeters, objective.status != .completed {
                Text(UnitFormatter.distance(meters: distanceMeters, units: units)).font(Theme.Typography.caption.monospacedDigit())
            }
            if objective.provisional {
                Image(systemName: "hourglass").font(.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }

    private var progressText: String? {
        guard objective.progress.target > 1, objective.status != .completed else { return nil }
        switch objective.objectiveType {
        case .completeDistance, .exploreNewRoads, .exploreDistance:
            return "\(UnitFormatter.distance(meters: objective.progress.current, units: units)) of \(UnitFormatter.distance(meters: objective.progress.target, units: units))"
        case .reachElevation, .completeClimb:
            return "\(Int(objective.progress.current)) of \(Int(objective.progress.target)) m"
        default:
            return "\(Int(objective.progress.current)) of \(Int(objective.progress.target))"
        }
    }
}
