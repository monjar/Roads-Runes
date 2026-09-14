import RoadsAndRunesCore
import SwiftUI

/// A chest, a piece or a monster on the World map: what it is, what it pays, how
/// to beat it, and one action — plan a route to it.
struct EncounterCard: View {
    let object: WorldObject
    var distanceMeters: Double?
    let units: Units
    let onPlan: () -> Void
    let onClose: () -> Void

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                EncounterGlyph(kind: object.kind, bounty: object.isBounty, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(object.name).font(Theme.Typography.voice(20, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                        if object.isBounty { Eyebrow(text: "Bounty", color: Theme.Colors.terracottaDeep) }
                    }
                    Text(facts).font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.muted).lineLimit(2)
                    if let flavour = object.monster?.flavour {
                        Text(flavour).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34, action: onClose)
                    .accessibilityLabel("Close")
            }
            if let monster = object.monster, !monster.killMethods.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to beat it").font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.ink)
                    ForEach(Array(monster.killMethods.enumerated()), id: \.offset) { _, method in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: Self.symbol(for: method.method))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.Colors.terracottaDeep)
                                .frame(width: 22)
                            Text(method.hint).font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
                        }
                    }
                }
            } else if object.kind == .chest {
                Text("Pass within \(Int(EncounterTracker.claimRadius[.chest] ?? 40)) m and it opens.").font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
            } else if object.kind == .collectable {
                Text("Pass close by to pick it up. Three pieces on one outing is a quest.").font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
            }
            Button(action: onPlan) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    Text("Plan a route here")
                }
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("encounter.plan")
        }
        .padding(18)
        .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("encounterCard")
    }

    private var facts: String {
        var parts: [String] = []
        if let anchor = object.anchorName { parts.append("at \(anchor)") }
        if let distanceMeters { parts.append(formatter.distance(meters: distanceMeters)) }
        parts.append("\(object.rewardAC) AC")
        let days = max(0, Int(object.expiresAt.timeIntervalSinceNow / 86_400))
        parts.append(days == 0 ? "gone tonight" : "\(days) day\(days == 1 ? "" : "s") left")
        return parts.joined(separator: " · ")
    }

    static func symbol(for method: KillMethodKind) -> String {
        switch method {
        case .pace: return "hare.fill"
        case .rune: return "scribble.variable"
        case .climb: return "mountain.2.fill"
        case .lore: return "square.and.pencil"
        case .explore: return "map.fill"
        case .unknown: return "questionmark"
        }
    }
}

/// The world object's mark: a box for a chest, a flame for a monster, sparkles for a piece.
struct EncounterGlyph: View {
    let kind: WorldObjectKind
    var bounty = false
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(Theme.Colors.cream)
            if bounty {
                Circle().stroke(Color(red: 0.85, green: 0.65, blue: 0.13), lineWidth: 3)
            }
        }
        .frame(width: size, height: size)
    }

    private var symbol: String {
        switch kind {
        case .chest: return "shippingbox.fill"
        case .monster: return "flame.fill"
        case .collectable: return "sparkles"
        case .unknown: return "questionmark"
        }
    }

    private var color: Color {
        switch kind {
        case .chest: return Theme.Colors.inkSoft
        case .monster: return Theme.Colors.terracottaDeep
        case .collectable: return Theme.Colors.sageDeep
        case .unknown: return Theme.Colors.muted
        }
    }
}
