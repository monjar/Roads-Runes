import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// A legend's page (0.8.0): its mark in a frame, its health as three phase bars
/// with a notch for each journey, what this phase is weak to and resists with
/// numbers, the journeys so far, "Plan a ride here", its one free move, and how
/// it heals and sleeps. Opened from its mark on the World map and from Next up.
struct LegendPage: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let legendId: UUID
    @State private var planning: Place?
    @State private var confirmingMove = false
    @State private var moved = false

    /// The page with its journeys once loaded; the list's copy until then.
    private var legend: Legend? {
        if let page = container.legends.page, page.id == legendId { return page }
        return container.legends.awake.flatMap { $0.id == legendId ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let legend {
                        content(legend)
                    } else {
                        EmptyState(icon: .fogDragon, title: "It has gone quiet", message: "It isn't awake any more. Another will wake soon.")
                    }
                }
                .padding(22)
            }
            .background(Theme.Colors.cream)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LoreCopy.done) { dismiss() }.accessibilityIdentifier("legendPage.done")
                }
            }
        }
        .task { await container.legends.loadPage(id: legendId) }
        .sheet(item: $planning) { place in RoutePlannerView(quest: nil, destination: place) }
        .accessibilityIdentifier("legendPage")
    }

    @ViewBuilder
    private func content(_ legend: Legend) -> some View {
        HStack {
            Spacer()
            LegendFrame(mark: .of(legend), label: legend.name).frame(width: 168, height: 168)
            Spacer()
        }
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: "A legend · \(legend.phaseLine)", color: Theme.Colors.terracottaDeep)
            Text(legend.name).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
            if let line = whereLine(legend) {
                Text(line).font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.muted)
            }
            if let lives = legend.livesAt, !lives.isEmpty {
                Text("Lives by \(lives).").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
        if let flavour = legend.flavour, !flavour.isEmpty {
            Text(flavour).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
        // Health, a bar for each phase, a notch for each journey.
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Health").font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Text("\(legend.healthLeft.formatted()) / \(legend.healthMax.formatted())")
                    .font(Theme.Typography.text(14, .semibold).monospacedDigit()).foregroundStyle(Theme.Colors.inkSoft)
            }
            LegendPhaseBars(legend: legend)
        }
        .card()
        if let phase = legend.currentPhase { thisPhase(phase) }
        journeys(legend)
        actions(legend)
        Text(LegendCopy.healsAndSleeps(healsPerWeek: legend.healsPerWeek, sleepsAfterDays: legend.sleepsAfterDays))
            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("legendPage.heals")
        if let rune = legend.rune {
            HStack(spacing: 10) {
                MarkView(.rune(rune)).frame(width: 30, height: 30)
                Text("Defeat it to take the \(rune.capitalized) rune.")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("legendPage.rune")
        }
        if let page = legend.page, !page.isEmpty {
            Text(page).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "At Stave Hill · 2.4 km away".
    private func whereLine(_ legend: Legend) -> String? {
        var parts: [String] = []
        if let anchor = legend.anchorName, !anchor.isEmpty { parts.append("At \(anchor)") }
        if let here = container.location.lastFix?.coordinate {
            parts.append("\(UnitFormatter(units: container.session.units).distance(meters: GeoMath.distance(here, legend.coordinate))) away")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One phase a journey and a day; today's already broke, if it did.
    private var legendPhaseRule: String {
        legend?.phaseBrokenToday == true
            ? "A phase broke today. The next one can break tomorrow."
            : "Only one phase breaks a journey, and one a day."
    }

    /// This phase's Weak to and Resists, each kind with what one of it does.
    private func thisPhase(_ phase: LegendPhase) -> some View {
        let sheet = container.session.character?.sheet ?? .neutral
        let constants = container.session.config?.combat ?? CombatConstants()
        let activity = container.session.defaultActivity
        let units = container.session.units
        func line(_ kind: String) -> some View {
            HStack(spacing: 10) {
                MarkView(.kind(kind)).frame(width: 22, height: 22)
                Text(LegendCopy.effort(kind, perUnit: phase.perUnit(kind, sheet: sheet, constants: constants, activity: activity), units: units))
                    .font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
            }
            .accessibilityElement(children: .combine)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("This phase").font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
            if !phase.weakTo.isEmpty {
                Eyebrow(text: "Weak to", color: Theme.Colors.sageDeep)
                ForEach(phase.weakTo, id: \.self) { line($0) }
            }
            if !phase.resists.isEmpty {
                Eyebrow(text: "Resists", color: Theme.Colors.terracottaDeep).padding(.top, 4)
                ForEach(phase.resists, id: \.self) { line($0) }
            }
            if phase.stopIsNote {
                Text("A stop of a few minutes beside it counts as a note.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
            }
            Text(legendPhaseRule).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("legendPage.thisPhase")
    }

    @ViewBuilder
    private func journeys(_ legend: Legend) -> some View {
        let hurt = (legend.journeys ?? []).filter { $0.damage > 0 }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Journeys so far", subtitle: hurt.isEmpty ? nil : "\(hurt.count)")
            if hurt.isEmpty {
                Text("None yet. Ride near it to hurt it.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            ForEach(Array(hurt.enumerated()), id: \.offset) { _, journey in
                HStack {
                    Text(LegendCopy.journey(journey)).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
                    Spacer()
                    Text("Phase \(journey.phase)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("legendPage.journeys")
    }

    @ViewBuilder
    private func actions(_ legend: Legend) -> some View {
        Button {
            planning = WorldViewModel.place(for: legend)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                Text(LegendCopy.planButton)
            }
        }
        .buttonStyle(.primary)
        .disabled(container.rideRecorder.isActive)
        .accessibilityIdentifier("legendPage.plan")
        if let error = container.legends.error { ErrorLine(text: error) }
        if legend.moved {
            Text(moved ? "Moved. It's waiting somewhere new." : "You've moved it once. It stays here now.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                .accessibilityIdentifier("legendPage.moved")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Can't reach it? Move it once.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                Button {
                    confirmingMove = true
                } label: {
                    HStack(spacing: 8) {
                        if container.legends.moving { ProgressView().tint(Theme.Colors.ink) }
                        Text(LegendCopy.moveButton)
                    }
                }
                .buttonStyle(.surfacePill)
                .disabled(container.legends.moving)
                .accessibilityIdentifier("legendPage.move")
                .confirmationDialog("Move \(legend.name)? You can only do this once.", isPresented: $confirmingMove, titleVisibility: .visible) {
                    Button("Move it") {
                        Task { moved = await container.legends.move(legend) }
                    }
                    .accessibilityIdentifier("legendPage.moveConfirm")
                    Button("Keep it here", role: .cancel) {}
                }
            }
        }
    }
}

/// A legend's mark in its frame: a double gold border round the token.
struct LegendFrame: View {
    let mark: Mark
    var label: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.Colors.surface)
            RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Theme.Colors.gold, lineWidth: 2.5)
            RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.Colors.gold.opacity(0.55), lineWidth: 1).padding(7)
            MarkView(mark, label: label).padding(20)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Health as three phase bars: what is left of each, a notch where each journey
/// left it, broken phases empty, the phase being fought in terracotta.
struct LegendPhaseBars: View {
    let legend: Legend

    private var phases: [LegendPhase] { legend.phases.sorted { $0.n < $1.n } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(phases) { phase in
                HStack(spacing: 10) {
                    Text("Phase \(phase.n)").font(Theme.Typography.captionStrong)
                        .foregroundStyle(phase.n == legend.currentPhase?.n ? Theme.Colors.ink : Theme.Colors.muted)
                        .frame(width: 58, alignment: .leading)
                    PhaseBar(fraction: phase.broken ? 0 : phase.fraction, notches: legend.notches(phase: phase.n),
                             current: phase.n == legend.currentPhase?.n)
                        .frame(height: 14)
                    Text(phase.broken ? "Broken" : "\(phase.healthLeft) / \(phase.healthMax)")
                        .font(Theme.Typography.caption.monospacedDigit())
                        .foregroundStyle(phase.broken ? Theme.Colors.sageDeep : Theme.Colors.muted)
                        .frame(width: 72, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Phase \(phase.n)")
                .accessibilityValue(phase.broken ? "Broken" : "Health \(phase.healthLeft) of \(phase.healthMax)")
                .accessibilityIdentifier("legendPage.phase.\(phase.n)")
            }
        }
    }
}

/// One phase's bar: health left from the left, a notch for each journey.
struct PhaseBar: View {
    let fraction: Double
    var notches: [Double] = []
    var current = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.track)
                Capsule().fill(current ? Theme.Colors.terracotta : Theme.Colors.hatch)
                    .frame(width: max(0, width * min(1, max(0, fraction))))
                // Where each journey left it: the share taken so far, measured from the full end.
                ForEach(Array(notches.enumerated()), id: \.offset) { _, taken in
                    Rectangle().fill(Theme.Colors.ink)
                        .frame(width: 2, height: geometry.size.height + 4)
                        .offset(x: max(0, min(width - 2, width * (1 - taken) - 1)))
                }
            }
        }
    }
}

// MARK: - Lairs

/// A lair on the World map (0.8.0): what to do and by when, how far along, and what it pays.
struct LairCard: View {
    let lair: WorldObject
    var distanceMeters: Double?
    let units: Units
    let onPlan: () -> Void
    let onClose: () -> Void

    var body: some View {
        let info = lair.lair ?? LairInfo(cells: [])
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MarkView(.lair).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Lair", color: Theme.Colors.sageDeep)
                    Text(lair.shownName).font(Theme.Typography.voice(20, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                    if let distanceMeters {
                        Text("\(UnitFormatter(units: units).distance(meters: distanceMeters)) away")
                            .font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.muted)
                    }
                }
                Spacer(minLength: 0)
                IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34, action: onClose)
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("lair.close")
            }
            Text(LairCopy.task(info)).font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                .accessibilityIdentifier("lair.task")
            HStack(spacing: 10) {
                ProgressTrack(fraction: Double(info.visitedCount) / Double(max(1, info.need)), fill: Theme.Colors.sage)
                Text(LairCopy.progress(visited: info.visitedCount, need: info.need))
                    .font(Theme.Typography.captionStrong.monospacedDigit()).foregroundStyle(Theme.Colors.sageDeep)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("lair.progress")
            HStack(alignment: .top, spacing: 8) {
                MarkView(.greatChest).frame(width: 22, height: 22)
                Text(LairCopy.reward).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onPlan) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    Text(LegendCopy.planButton)
                }
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("lair.plan")
        }
        .padding(18)
        .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lairCard")
    }
}

// MARK: - Treasure maps

/// An open treasure map clue, on the Quests tab (0.8.0). Never a marker: only the words.
struct TreasureClueCard: View {
    let clue: TreasureClue

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MarkView(.treasureMap).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Treasure map", color: Theme.Colors.terracottaDeep)
                Text(clue.clue).font(Theme.Typography.voice(17, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("treasureClue.text")
                Text(TreasureCopy.howTo).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).stroke(Theme.Colors.terracotta.opacity(0.5), lineWidth: 1.2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("treasureClue")
    }
}

/// What a treasure map said when it was used: the clue, and where it will be kept.
struct TreasureClueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let clue: TreasureClue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Spacer()
                MarkView(.treasureMap, label: "Treasure map").frame(width: 96, height: 96)
                Spacer()
            }
            Eyebrow(text: "The clue", color: Theme.Colors.terracottaDeep)
            Text(clue.clue).font(Theme.Typography.voice(22, relativeTo: .title2)).foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("treasureSheet.clue")
            Text("\(TreasureCopy.howTo) The clue is kept on the Quests tab.")
                .font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(LoreCopy.done) { dismiss() }
                .buttonStyle(.primary)
                .accessibilityIdentifier("treasureSheet.done")
        }
        .padding(24)
        .background(Theme.Colors.cream)
        .presentationDetents([.medium])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("treasureSheet")
    }
}

// MARK: - Codex

/// A legend's Codex page: met, or defeated, with its page.
struct LegendCodexPage: View {
    let legend: LegendSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    LegendFrame(mark: .of(legend), label: legend.name).frame(width: 160, height: 160)
                    Spacer()
                }
                Text(legend.name).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                Eyebrow(text: legend.status == LegendStatus.defeated ? "Defeated" : "Met", color: Theme.Colors.sageDeep)
                if let flavour = legend.flavour, !flavour.isEmpty {
                    Text(flavour).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                if let page = legend.page, !page.isEmpty {
                    Text(page).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                if let rune = legend.rune {
                    HStack(spacing: 10) {
                        MarkView(.rune(rune)).frame(width: 30, height: 30)
                        Text(legend.status == LegendStatus.defeated ? "It left the \(rune.capitalized) rune." : "It leaves the \(rune.capitalized) rune.")
                            .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(22)
        }
        .background(Theme.Colors.cream)
        .navigationTitle(legend.name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("codex.legendPage")
    }
}
