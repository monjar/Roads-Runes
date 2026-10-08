import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Quest page (design 16a): diamond and QUEST eyebrow in sage, the quest name,
/// the fight beside it (0.7.2), the current objective, the distance to it, progress.
struct QuestScreen: View {
    @Environment(RideStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WatchTheme.sageLight)
                            .frame(width: 10, height: 10)
                            .rotationEffect(.degrees(45))
                        Text("QUEST")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(WatchTheme.sageLight)
                    }
                    Text(store.questTitle ?? LoreCopy.free(store.activity))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WatchTheme.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 2)
                }
                // The fight: a mark and a ring, nothing more to read on the move. A
                // legend's ring comes in its three phases.
                if let fight = store.fight {
                    Spacer(minLength: 0)
                    if fight.isLegend {
                        PhaseRing(fight: fight)
                            .frame(width: 46, height: 46)
                    } else {
                        FightRing(fight: fight)
                            .frame(width: 42, height: 42)
                    }
                }
            }
            if let encounter = store.encounterLine {
                Text(encounter)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WatchTheme.accent)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            if let objective = store.objectiveTitle {
                Text("OBJECTIVE")
                    .font(.system(size: 11))
                    .foregroundStyle(WatchTheme.tertiary)
                    .padding(.top, 10)
                Text(objective)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let distance = store.objectiveDistanceMeters {
                    let parts = split(store.formatter.distance(meters: distance))
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(parts.value)
                            .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        Text(parts.unit)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(WatchTheme.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
                Text(progressText)
                    .font(.system(size: 12))
                    .foregroundStyle(WatchTheme.tertiary)
            } else {
                Spacer(minLength: 0)
                Text(store.questTitle == nil ? "Every new road counts" : "All objectives complete")
                    .font(.system(size: 14))
                    .foregroundStyle(WatchTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private var progressText: String {
        let total = store.summary?.objectives.count ?? 0
        guard total > 0 else { return "" }
        let done = store.summary?.objectives.filter { $0.title != store.objectiveTitle }.count ?? 0
        return "\(min(done + 1, total)) of \(total) objectives"
    }

    private func split(_ distance: String) -> (value: String, unit: String) {
        guard let space = distance.lastIndex(of: " ") else { return (distance, "") }
        return (String(distance[..<space]), String(distance[distance.index(after: space)...]))
    }
}

/// The creature being fought, inside its health drawn as ten ticks (`HoldRing`):
/// redrawn in whole tenths, with no numbers and no animation. Defeated, the ring
/// is empty and the mark fades.
struct FightRing: View {
    let fight: WatchFight

    var body: some View {
        ZStack {
            HoldRing(fraction: Self.fraction(tenths: fight.tenthsLeft), palette: .watch, lineWidth: 3)
            MarkView(WristMarks.fight(fight), palette: .watch)
                .padding(7)
                .opacity(fight.defeated ? 0.45 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fight.defeated ? "\(fight.name), defeated" : "\(fight.name), health \(fight.tenthsLeft) of 10")
    }

    /// Half a tenth under the count, so the ring's rounding up lands on it exactly.
    static func fraction(tenths: Int) -> Double {
        tenths <= 0 ? 0 : (Double(min(10, tenths)) - 0.5) / 10
    }
}

/// A legend inside its health drawn as one arc per phase (0.8.0): the broken ones
/// filled in gold, the one it is on in ten ticks redrawn in whole tenths, those
/// still to come whole and quieter. No numbers and no animation, as `FightRing`.
struct PhaseRing: View {
    let fight: WatchFight

    var body: some View {
        ZStack {
            PhaseArcs(arcs: Self.arcs(for: fight), palette: .watch, lineWidth: 3)
            MarkView(WristMarks.fight(fight), palette: .watch)
                .padding(8)
                .opacity(fight.defeated ? 0.45 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(for: fight))
    }

    /// What one phase's arc shows.
    enum Arc: Equatable {
        /// Broken: filled in gold.
        case broken
        /// The phase it is on, with this many tenths left.
        case current(tenths: Int)
        /// Still to come: whole.
        case whole
    }

    /// One arc per phase, in order round the ring from the top.
    static func arcs(for fight: WatchFight) -> [Arc] {
        let phases = fight.phases ?? 1
        let broken = fight.phasesBroken
        return (0..<phases).map { index in
            if index < broken { return .broken }
            return index == broken ? .current(tenths: fight.tenthsLeft) : .whole
        }
    }

    static func label(for fight: WatchFight) -> String {
        if fight.defeated { return "\(fight.name), defeated" }
        return "\(fight.name), phase \(fight.phase ?? 1) of \(fight.phases ?? 1), health \(fight.tenthsLeft) of 10"
    }
}

/// The phases' arcs, drawn the way `HoldRing` draws its ticks.
struct PhaseArcs: View {
    let arcs: [PhaseRing.Arc]
    let palette: InkPalette
    let lineWidth: CGFloat

    /// Degrees left empty between two phases, and between two ticks of the one it is on.
    static let phaseGap = 8.0
    static let tickGap = 2.0

    var body: some View {
        Canvas { context, size in
            guard !arcs.isEmpty else { return }
            let radius = min(size.width, size.height) / 2 - lineWidth
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let span = 360.0 / Double(arcs.count)
            let gold = Color(cgColor: (palette.spots[.gold] ?? palette.ink).cgColor)
            let ink = Color(cgColor: palette.ink.cgColor)
            let soft = Color(cgColor: palette.inkSoft.cgColor).opacity(0.6)
            let empty = Color(cgColor: palette.hatch.cgColor).opacity(0.45)
            func stroke(_ from: Double, _ to: Double, _ color: Color) {
                var arc = Path()
                arc.addArc(center: centre, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
            for (index, arc) in arcs.enumerated() {
                let from = -90 + Double(index) * span + Self.phaseGap / 2
                let to = -90 + Double(index + 1) * span - Self.phaseGap / 2
                switch arc {
                case .broken:
                    stroke(from, to, gold)
                case .whole:
                    stroke(from, to, soft)
                case .current(let tenths):
                    let tick = (to - from) / 10
                    for i in 0..<10 {
                        stroke(from + Double(i) * tick + Self.tickGap / 2, from + Double(i + 1) * tick - Self.tickGap / 2,
                               i < tenths ? ink : empty)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .transaction { $0.animation = nil }
    }
}
