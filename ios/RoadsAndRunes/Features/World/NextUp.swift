import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// What to do next, in one sentence and one button, on the World map
/// (docs/ROADMAP.md, 0.7.1). A new player used to land on a map of unexplained
/// marks with nothing saying where to start. The first that applies wins.
enum NextUp: Equatable {
    /// Nothing earned yet: go out once.
    case firstRide
    /// A chest or a rune stone close enough to take now.
    case inReach(WorldObject)
    /// Skill points waiting and a skill that can be learned.
    case skillPoints(Int)
    /// The legend awake (0.8.0), when it is in reach: it outranks a creature.
    case legend(Legend, meters: Double)
    /// The nearest creature worth riding to.
    case creature(WorldObject, meters: Double)
    /// The nearest chest worth riding to.
    case treasure(WorldObject, meters: Double)
    /// Nothing near: the quest board has something.
    case quests

    /// How far a creature or a chest may be and still be "next".
    static let nearMeters: Double = 3000
    /// How far a legend may be and still be in reach: it lives 2–8 km from where you start.
    static let legendReachMeters: Double = 8000

    static func choose(
        character: Character?,
        objects: [WorldObject],
        position: Coordinate?,
        legend: Legend? = nil,
        inReach: (WorldObject) -> Bool
    ) -> NextUp {
        if let character, character.overallXP == 0 { return .firstRide }
        let live = objects.filter { $0.status == .spawned }
        if let reachable = live.first(where: { $0.kind != .monster && inReach($0) }) {
            return .inReach(reachable)
        }
        if let character, character.unspentAbilityPoints > 0, character.abilities.contains(where: \.canUnlock) {
            return .skillPoints(character.unspentAbilityPoints)
        }
        guard let position else { return .quests }
        let near = live
            .map { (object: $0, meters: GeoMath.distance(position, $0.coordinate)) }
            .filter { $0.meters <= nearMeters }
            .sorted { $0.meters < $1.meters }
        // The bounty first, then the legend in reach, then the nearest creature, then the nearest chest.
        if let bounty = near.first(where: { $0.object.isBounty }) {
            return .creature(bounty.object, meters: bounty.meters)
        }
        if let legend, legend.isAwake {
            let meters = GeoMath.distance(position, legend.coordinate)
            if meters <= legendReachMeters { return .legend(legend, meters: meters) }
        }
        if let creature = near.first(where: { $0.object.kind == .monster }) {
            return .creature(creature.object, meters: creature.meters)
        }
        if let chest = near.first(where: { $0.object.kind == .chest }) {
            return .treasure(chest.object, meters: chest.meters)
        }
        return .quests
    }
}

/// The card for `NextUp`: the thing's mark, a line saying what it is, a line
/// saying what to do, and one button that does it.
struct NextUpCard: View {
    let next: NextUp
    let units: Units
    let activity: Activity
    /// Today's pledge, as a row under the card's line (0.7.3).
    var pledge: Pledge? = nil
    let onAction: () -> Void

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            main
            if let pledge {
                Divider().overlay(Theme.Colors.line)
                PledgeRow(pledge: pledge)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.16), radius: 6, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nextUp")
    }

    private var main: some View {
        HStack(spacing: 12) {
            MarkView(mark).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                Text(detail)
                    .font(Theme.Typography.text(12, relativeTo: .caption)).foregroundStyle(Theme.Colors.muted).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(action: onAction) {
                Text(button)
                    .font(Theme.Typography.text(13, .semibold))
                    .foregroundStyle(Theme.Colors.cream)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Theme.Colors.terracotta, in: Capsule())
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("nextUp.action")
        }
    }

    private var mark: Mark {
        switch next {
        case .firstRide: return .rider(activity.rawValue)
        case .inReach(let object), .creature(let object, _), .treasure(let object, _): return .of(object)
        case .legend(let legend, _): return .of(legend)
        case .skillPoints: return .token(.star, ring: .gold)
        case .quests: return .quest
        }
    }

    private var title: String {
        switch next {
        case .firstRide: return "Your first \(activity.noun)"
        case .inReach(let object): return "\(object.name) is in reach"
        case .skillPoints(let count): return count == 1 ? "A skill point to spend" : "\(count) skill points to spend"
        case .creature(let object, let meters), .treasure(let object, let meters):
            return "\(object.name) · \(formatter.distance(meters: meters))"
        case .legend(let legend, let meters):
            return "\(legend.name) · \(formatter.distance(meters: meters))"
        case .quests: return "Find a quest"
        }
    }

    private var detail: String {
        switch next {
        case .firstRide: return "Plan one and see what's out there."
        case .inReach(let object):
            return object.kind == .chest ? "Open it for \(LoreCopy.purse(object.rewardAC))." : "Pick it up."
        case .skillPoints: return "Learn a new skill on your character."
        case .creature(let object, _):
            let at = object.anchorName.map { "At \($0). " } ?? ""
            return object.isBounty ? "\(at)Today's bounty: worth double." : "\(at)Ride near it to defeat it."
        case .treasure(let object, _): return "Open it for \(LoreCopy.purse(object.rewardAC))."
        case .legend(let legend, _):
            let weak = legend.currentPhase.map { " \(LoreCopy.weakTo($0.weakTo))." } ?? ""
            return "A legend · \(legend.phaseLine).\(weak)"
        case .quests: return "The board has quests near you."
        }
    }

    private var button: String {
        switch next {
        case .firstRide: return "Plan"
        case .inReach(let object): return object.kind == .chest ? "Open" : "Pick up"
        case .skillPoints: return "Learn"
        case .creature, .treasure, .legend: return "Go"
        case .quests: return "Quests"
        }
    }
}
