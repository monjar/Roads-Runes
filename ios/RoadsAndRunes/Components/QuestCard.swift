import RoadsAndRunesCore
import SwiftUI

/// Quest row from the World's Nearby sheet (design 9a): class tile, eyebrow,
/// Caprasimo title, one line of facts, chevron.
struct QuestCard: View {
    let quest: Quest
    var compact = false
    let units: Units
    var distanceMeters: Double? = nil

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(ClassStyle.color(quest.characterClass))
                Image(systemName: ClassStyle.symbol(quest.characterClass))
                    .font(.system(size: compact ? 18 : 26, weight: .bold))
                    .foregroundStyle(Theme.Colors.cream)
            }
            .frame(width: compact ? 44 : 64, height: compact ? 44 : 64)
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: eyebrow, color: ClassStyle.textColor(quest.characterClass))
                Text(quest.title)
                    .font(compact ? Theme.Typography.cardTitle : Theme.Typography.voice(18, relativeTo: .title3))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(2)
                Text(facts).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private var eyebrow: String {
        var parts = ["\(ClassStyle.name(quest.characterClass)) quest"]
        if let distanceMeters { parts.append("\(formatter.distance(meters: distanceMeters)) away") }
        switch quest.status {
        case .active: parts.append("in progress")
        case .accepted: parts.append("accepted")
        case .completed: parts.append("completed")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    private var facts: String {
        let objectives = quest.requiredObjectives.count
        return [
            formatter.distance(meters: quest.recommendedDistanceKm * 1000),
            quest.difficulty.rawValue.lowercased(),
            "\(objectives) objective\(objectives == 1 ? "" : "s")",
            "\(quest.rewards.xp ?? quest.baseXP) XP",
        ].joined(separator: " · ")
    }
}

/// Objective as a numbered diamond (design 10a). Exploration objectives use
/// terracotta, optional ones a dashed outline, completed ones a check.
struct ObjectiveRow: View {
    let objective: Objective
    var distanceMeters: Double? = nil
    let units: Units
    var index: Int? = nil
    var accent: Color = Theme.Colors.sage

    private var done: Bool { objective.status == .completed }

    var body: some View {
        HStack(spacing: 12) {
            DiamondMarker(
                color: isExploration ? Theme.Colors.terracotta : accent,
                label: index.map(String.init),
                dashed: !objective.required && !done,
                done: done
            )
            Text(objective.title)
                .font(Theme.Typography.text(14))
                .foregroundStyle(done ? Theme.Colors.muted : Theme.Colors.ink)
                .strikethrough(done, color: Theme.Colors.muted)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
            if objective.provisional == true {
                Image(systemName: "hourglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.muted)
            }
        }
    }

    private var isExploration: Bool {
        switch objective.objectiveType {
        case .exploreDistance, .exploreNewRoads: return true
        default: return false
        }
    }

    private var trailing: String? {
        if done { return objective.provisional == true ? "pending" : "done" }
        if let progress = progressText { return progress }
        if let distanceMeters { return UnitFormatter(units: units).distance(meters: distanceMeters) }
        if !objective.required { return "optional" }
        if objective.objectiveType == .visitPOI, objective.discoveryId != nil, objective.latitude == nil { return "hidden" }
        return nil
    }

    private var progressText: String? {
        guard objective.progress.target > 1, objective.status != .completed else { return nil }
        let f = UnitFormatter(units: units)
        switch objective.objectiveType {
        case .completeDistance, .exploreNewRoads, .exploreDistance:
            return "\(f.distance(meters: objective.progress.current)) of \(f.distance(meters: objective.progress.target))"
        case .reachElevation, .completeClimb:
            return "\(Int(objective.progress.current)) of \(Int(objective.progress.target)) m"
        default:
            return "\(Int(objective.progress.current)) of \(Int(objective.progress.target))"
        }
    }
}

/// The current quest as the big ink card (design 9b): eyebrow, Caprasimo title,
/// one line of story, three facts, Continue.
struct CurrentQuestCard: View {
    let quest: Quest
    let units: Units
    let onContinue: () -> Void
    let onDetails: () -> Void

    var body: some View {
        let f = UnitFormatter(units: units)
        let left = quest.requiredObjectives.filter { $0.status != .completed }.count
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Current quest · \(left) objective\(left == 1 ? "" : "s") left", color: ClassStyle.lightColor(quest.characterClass))
            Text(quest.title).font(Theme.Typography.title).foregroundStyle(Theme.Colors.cream).lineLimit(2)
            Text(quest.narrative.hook ?? quest.description).font(Theme.Typography.text(13.5)).foregroundStyle(Theme.Colors.line).lineLimit(2)
            HStack(spacing: 14) {
                Text(f.distance(meters: quest.recommendedDistanceKm * 1000))
                Text(quest.difficulty.rawValue.capitalized)
                Text("+\(quest.rewards.xp ?? quest.baseXP) XP").foregroundStyle(ClassStyle.lightColor(quest.characterClass))
            }
            .font(Theme.Typography.text(14, .semibold))
            .foregroundStyle(Theme.Colors.cream)
            HStack(spacing: 8) {
                Button("Continue", action: onContinue)
                    .font(Theme.Typography.buttonSmall)
                    .foregroundStyle(Theme.Colors.cream)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.Colors.terracotta, in: Capsule())
                Button("Details", action: onDetails)
                    .font(Theme.Typography.text(13, .semibold))
                    .foregroundStyle(Theme.Colors.cream)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .overlay(Capsule().stroke(Theme.Colors.cream.opacity(0.2), lineWidth: 1))
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                Theme.Colors.ink
                RingPattern(color: Theme.Colors.cream, opacity: 0.08, step: 10).frame(width: 200, height: 200).offset(x: 40, y: -40)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        )
    }
}
