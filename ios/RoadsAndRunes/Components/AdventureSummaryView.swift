import RoadsAndRunesCore
import SwiftUI

/// Ride completion screen (spec §40): adventure progress first, cycling stats last.
struct AdventureSummaryView: View {
    let summary: AdventureSummary
    let units: Units
    let onDone: () -> Void

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                Text("ADVENTURE COMPLETE").font(Theme.Typography.caption.weight(.bold)).tracking(3).foregroundStyle(Theme.Colors.rune)
                if let quest = summary.quest {
                    VStack(spacing: Theme.Spacing.xs) {
                        Text(quest.title).font(Theme.Typography.display).multilineTextAlignment(.center)
                        Text(summary.questCompletion != nil ? "Quest complete" : "Quest in progress").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                Text("+\(summary.xpAwarded) XP").font(.system(size: 56, weight: .bold, design: .rounded)).foregroundStyle(Theme.Colors.moss)

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    summaryLine(icon: "sparkles", text: "\(summary.discoveries.count) discover\(summary.discoveries.count == 1 ? "y" : "ies")")
                    summaryLine(icon: "map", text: "\(formatter.distance(meters: summary.newTerritoryMeters)) new territory")
                    summaryLine(icon: "hexagon", text: "\(summary.newCells) new areas uncovered")
                    ForEach(summary.levelUps.indices, id: \.self) { i in
                        let lu = summary.levelUps[i]
                        summaryLine(icon: "arrow.up.circle.fill", text: "\(lu.kind == .classLevel ? "Class level" : "Level") \(lu.from) → \(lu.to)", accent: true)
                    }
                    ForEach(summary.abilitiesUnlocked, id: \.id) { ability in
                        summaryLine(icon: "lock.open.fill", text: "\(ability.name) available", accent: true)
                    }
                    ForEach(summary.titlesUnlocked ?? [], id: \.self) { title in
                        summaryLine(icon: "crown.fill", text: "Title earned: \(title)", accent: true)
                    }
                }
                .card()

                if !summary.xpBreakdown.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(summary.xpBreakdown.indices, id: \.self) { i in
                            let line = summary.xpBreakdown[i]
                            HStack {
                                Text(line.source.replacingOccurrences(of: "_", with: " ").capitalized).font(Theme.Typography.caption)
                                Spacer()
                                Text("+\(line.xp)").font(Theme.Typography.caption.monospacedDigit())
                            }
                        }
                    }
                    .card()
                }

                HStack(spacing: Theme.Spacing.lg) {
                    RideMetric(title: "Ridden", value: formatter.distance(meters: summary.ride.distanceMeters), compact: true)
                    RideMetric(title: "Climbed", value: formatter.elevation(meters: summary.ride.elevationGainMeters), compact: true)
                    RideMetric(title: "Time", value: formatter.duration(seconds: Double(summary.ride.durationSeconds)), compact: true)
                }

                if !summary.flags.isEmpty {
                    Text("Some data could not be validated: \(summary.flags.joined(separator: ", "))").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember)
                }

                Button("Back to the world", action: onDone).buttonStyle(.borderedProminent).tint(Theme.Colors.moss).controlSize(.large)
            }
            .padding(Theme.Spacing.lg)
        }
        .background(Theme.Colors.parchment.ignoresSafeArea())
    }

    private func summaryLine(icon: String, text: String, accent: Bool = false) -> some View {
        Label(text, systemImage: icon).font(Theme.Typography.body).foregroundStyle(accent ? Theme.Colors.rune : Theme.Colors.textPrimary)
    }
}
