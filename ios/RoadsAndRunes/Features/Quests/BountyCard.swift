import RoadsAndRunesCore
import SwiftUI

/// Today's bounty on the Quests tab: one monster, twice the purse, gone at midnight.
struct BountyCard: View {
    let bounty: WorldObject
    var distanceMeters: Double?
    let units: Units
    let onPlan: () -> Void

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        Button(action: onPlan) {
            HStack(spacing: 14) {
                EncounterGlyph(kind: .monster, bounty: true, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Today's bounty", color: Theme.Colors.terracottaDeep)
                    Text(bounty.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                    Text(facts).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Colors.muted)
            }
            .padding(16)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color(red: 0.85, green: 0.65, blue: 0.13).opacity(0.7), lineWidth: 1.5))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("bounty")
    }

    private var facts: String {
        var parts: [String] = []
        if let anchor = bounty.anchorName { parts.append("at \(anchor)") }
        if let distanceMeters { parts.append(formatter.distance(meters: distanceMeters)) }
        parts.append("\(bounty.rewardAC) AC · gone tonight")
        if let first = bounty.monster?.killMethods.first { parts.append(first.hint) }
        return parts.joined(separator: " · ")
    }
}
