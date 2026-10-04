import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// A chest, a piece or a monster on the World map: what it is, what it pays and
/// how to get it. Within reach of a chest or a piece the action is to take it;
/// further off, and for a monster, it is to plan a route there.
struct EncounterCard: View {
    let object: WorldObject
    var distanceMeters: Double?
    let units: Units
    /// The player is close enough to open it or pick it up.
    var inReach = false
    /// How much of the ground round it is new to the player, once known.
    var groundRound: WorldViewModel.GroundRound?
    var claiming = false
    var claimError: String?
    var onClaim: () -> Void = {}
    let onPlan: () -> Void
    let onClose: () -> Void

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                EncounterGlyph(object: object, size: 48)
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
            if let monster = object.monster, monster.foughtByEffort {
                wantsSection(monster)
            } else if let monster = object.monster, !monster.killMethods.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What it wants").font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.ink)
                    ForEach(Array(monster.killMethods.enumerated()), id: \.offset) { _, method in
                        HStack(alignment: .top, spacing: 10) {
                            MarkView(.icon(Self.icon(for: method.method), spot: .terracotta))
                                .frame(width: 18, height: 18)
                                .frame(width: 22)
                            Text(method.hint).font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
                        }
                    }
                }
            } else if let reach = object.reachMeters {
                Text(howToTakeIt(reach)).font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
                    .accessibilityIdentifier("encounter.reach")
            }
            if let standing = object.setStanding {
                // Which set, how much of it is held, and whether this piece adds to it.
                HStack(spacing: 6) {
                    MarkView(.icon(.sparkles, spot: .sage)).frame(width: 16, height: 16)
                    Text(standing.line + (object.pieceOwned == true ? " · you have this one" : ""))
                }
                .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                    .accessibilityIdentifier("encounter.set")
            }
            if let claimError { ErrorLine(text: claimError) }
            if inReach, object.reachMeters != nil {
                Button(action: onClaim) {
                    ZStack {
                        HStack(spacing: 10) {
                            MarkView(.icon(object.kind == .chest ? .openChest : .runeStone, spot: .paper)).frame(width: 20, height: 20)
                            Text(object.kind == .chest ? "Open chest" : "Pick it up")
                        }
                        .opacity(claiming ? 0 : 1)
                        if claiming { ProgressView().tint(Theme.Colors.cream) }
                    }
                }
                .buttonStyle(.primary)
                .disabled(claiming)
                .accessibilityIdentifier("encounter.claim")
            } else {
                Button(action: onPlan) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                        Text("Plan a route here")
                    }
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("encounter.plan")
            }
        }
        .padding(18)
        .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("encounterCard")
    }

    /// Effort is damage: what it wants and shrugs at, its hold, its rune and the
    /// rune's road form, how long since anyone read the place, and how much of the
    /// ground round it is new. Numbers are fine here: the card is read at rest.
    @ViewBuilder
    private func wantsSection(_ monster: MonsterInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What it wants").font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.ink)
            row(.sword, LoreCopy.wants(monster.wants ?? [], rune: Self.runeName(monster.rune), runeForm: monster.roadForm))
                .accessibilityIdentifier("encounter.wants")
            if let minds = monster.minds, !minds.isEmpty {
                row(.resist, LoreCopy.doesNotMind(minds)).accessibilityIdentifier("encounter.minds")
            }
            if let holdMax = monster.holdMax {
                let left = monster.holdLeft ?? holdMax
                row(.heart, left < holdMax ? "Its hold: \(left) of \(holdMax). Loosened." : "Its hold: \(holdMax).")
                    .accessibilityIdentifier("encounter.hold")
            }
            if let rune = Self.runeName(monster.rune), let form = LoreCopy.roadForm(monster.roadForm) {
                row(.runeStone, "\(rune). On the road, \(form).")
            }
            if let days = monster.unpassedDays, days >= 30 {
                row(.hourglass, "You have not passed here in \(days) days.")
            }
            if let groundRound, groundRound.of > 0 {
                row(.treasureMap, groundRound.unread == 0
                    ? "You have read all the ground round it."
                    : "\(groundRound.unread) of the \(groundRound.of) patches round it are new ground to you.")
                    .accessibilityIdentifier("encounter.ground")
            }
        }
    }

    private func row(_ icon: GameIcon, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            MarkView(.icon(icon, spot: .terracotta))
                .frame(width: 18, height: 18)
                .frame(width: 22)
            Text(text).font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "kenaz" → "Kenaz".
    static func runeName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return id.prefix(1).uppercased() + id.dropFirst()
    }

    /// Within reach it says so; out of reach it says how much closer to get.
    private func howToTakeIt(_ reach: Double) -> String {
        let piece = object.kind == .collectable
        if inReach { return piece ? "You are close enough to pick it up." : "You are close enough to open it." }
        let within = "Get within \(formatter.distance(meters: reach))"
        guard let distanceMeters, distanceMeters > reach else { return "\(within) to \(piece ? "pick it up" : "open it")." }
        return "\(within) to \(piece ? "pick it up" : "open it") · \(formatter.distance(meters: distanceMeters - reach)) to go."
    }

    private var facts: String {
        var parts: [String] = []
        if let anchor = object.anchorName { parts.append("at \(anchor)") }
        if let distanceMeters { parts.append(formatter.distance(meters: distanceMeters)) }
        parts.append(LoreCopy.purse(object.rewardAC))
        let days = max(0, Int(object.expiresAt.timeIntervalSinceNow / 86_400))
        parts.append(days == 0 ? "its last day" : "\(days) day\(days == 1 ? "" : "s") left")
        return parts.joined(separator: " · ")
    }

    static func icon(for method: KillMethodKind) -> GameIcon {
        switch method {
        case .pace: return .road
        case .rune: return .runeStone
        case .climb: return .climb
        case .lore: return .note
        case .explore: return .treasureMap
        case .unknown: return .mystery
        }
    }
}

/// The world object's face (RoadsAndRunesArt): a creature's sigil in its tier's
/// frame, a chest by tier, a rune-stone or a coin for a piece.
struct EncounterGlyph: View {
    let mark: Mark
    var size: CGFloat = 40

    init(object: WorldObject, size: CGFloat = 40) {
        mark = .of(object)
        self.size = size
    }

    /// For a place that has only the kind.
    init(kind: WorldObjectKind, bounty: Bool = false, size: CGFloat = 40) {
        mark = .of(kind: kind, bounty: bounty)
        self.size = size
    }

    var body: some View {
        MarkView(mark).frame(width: size, height: size)
    }
}
