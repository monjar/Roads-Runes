import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Adventure Complete (design 13b): Journey's end.
///
/// The ride's line draws itself on the map, then what it earned arrives a part at
/// a time: the XP counts up and the level fills, each line of it lands, then the
/// coins, then a level gained (its own card), then what was defeated, opened and
/// found — and what got away, and by how much — then the quest's last word.
/// With fights decided by effort, the fights come first, the quarry leading. It
/// was one static sheet with a level-up as a small chip among others. One tap
/// shows everything at once; "Done" is there from the start. Cycling
/// stats stay one quiet line (spec §40). Opened again from the Journal it is
/// simply all there (`animated: false`).
struct AdventureSummaryView: View {
    @Environment(AppContainer.self) private var container
    let summary: AdventureSummary
    let units: Units
    var animated = true
    let onDone: () -> Void

    @State private var geometry: RideGeometry?
    @State private var offerStrava = false
    @State private var stravaState: StravaLineState = .idle
    @State private var stage: Stage = .trace
    @State private var shownXP: Double = 0
    @State private var shownCoins: Double = 0
    @State private var levelFill: Double = 0
    @State private var linesShown = 0
    @State private var traceShown = 1.0
    @State private var camera: MapCamera?
    @State private var reveal: Task<Void, Never>?
    @State private var sharing = false
    /// "Save for Garmin": the journey as a FIT activity, imported by hand (docs/GARMIN.md, B1).
    @State private var export: ExportRequest?

    private enum StravaLineState { case idle, sending, sent, failed(String) }

    /// The order things arrive in.
    private enum Stage: Int, Comparable {
        case trace, fight, legend, xp, lines, coins, levels, world, districts, lair, treasure, codex, runes, items, quest, entry, rest

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Average H3 resolution-9 cell area, km².
    private static let cellAreaKm2 = 0.1053

    private var formatter: UnitFormatter { UnitFormatter(units: units) }
    private var character: Character? { container.session.character }
    private var coins: Int { summary.acAwarded ?? 0 }
    private var xpLines: [XPBreakdownEntry] { summary.xpBreakdown.filter { $0.xp > 0 } }
    private var coinLines: [ACBreakdownEntry] { (summary.acBreakdown ?? []).filter { $0.ac > 0 } }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Colors.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    MapLibreView(
                        styleURL: Config.mapStyleURL(for: .minimal),
                        center: geometry?.path.first ?? summary.quest?.origin,
                        zoom: 12.5,
                        cells: [],
                        route: drawnTrace,
                        markers: markers,
                        camera: camera
                    )
                    .ignoresSafeArea(edges: .top)
                    StatusPill(text: revealLine, dot: Theme.Colors.sageLight).padding(.top, 8)
                }
                .frame(height: 430)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            SheetHandle().frame(maxWidth: .infinity)
                            header
                            if stage >= .fight, !fights.isEmpty { fightSection.id(Stage.fight) }
                            // The legend (0.8.0): damage, the phase bar, "Phase broken!", what it paid.
                            if stage >= .legend, let legend = summary.legend { LegendOutcomeSection(outcome: legend).id(Stage.legend) }
                            if stage >= .legend, let woke = summary.legendWoke { LegendWokeLine(woke: woke) }
                            if stage >= .xp, animated, let character { levelBar(character) }
                            if stage >= .lines, !xpLines.isEmpty { breakdown(xpLines.map { (RewardCopy.xp(source: $0.source, className: className), "+\($0.xp)") }).id(Stage.lines) }
                            if stage >= .coins, coins > 0 { coinSection.id(Stage.coins) }
                            if stage >= .levels { levelCards.id(Stage.levels) }
                            if stage >= .world { worldSection.id(Stage.world) }
                            // A pledge kept (0.7.3): said once, with the thing's mark. A missed one is never mentioned.
                            if stage >= .world, let kept = summary.pledge, kept.kept { PledgeKeptLine(kept: kept) }
                            // The districts passed through, made yours or completed, and the week's pay (0.9.0).
                            if stage >= .districts, hasDistricts { districtsSection.id(Stage.districts) }
                            // A lair's tiles, or its great chest; buried treasure found (0.8.0).
                            if stage >= .lair, let lair = summary.lair { LairOutcomeSection(outcome: lair).id(Stage.lair) }
                            if stage >= .treasure, !summary.treasures.isEmpty { TreasureFoundSection(finds: summary.treasures).id(Stage.treasure) }
                            if stage >= .codex, !firsts.isEmpty { codexSection.id(Stage.codex) }
                            if stage >= .runes, !runeLines.isEmpty { runesSection.id(Stage.runes) }
                            if stage >= .items, !finds.isEmpty { itemsSection.id(Stage.items) }
                            if stage >= .quest { questSection.id(Stage.quest) }
                            if stage >= .quest, let goal = sealedGoal { sealedSection(goal) }
                            if stage >= .entry, let entry = summary.entryToRead, !entry.isEmpty { entrySection(entry).id(Stage.entry) }
                            // Letters written here a season or more ago, found again (0.7.3).
                            if stage >= .entry, let letters = summary.letters, !letters.isEmpty { FoundLettersSection(letters: letters) }
                            if stage >= .rest { restSection.id(Stage.rest) }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .contentShape(Rectangle())
                        .onTapGesture { showEverything() }
                    }
                    .onChange(of: stage) { _, now in
                        guard animated, now > .xp else { return }
                        withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(now, anchor: .bottom) }
                    }
                }
                // Read again from the Journal there is nothing left to collect.
                Button(LoreCopy.done) {
                    if animated { Task { await container.nudges.requestAuthorizationIfNeeded() } }
                    onDone()
                }
                .buttonStyle(.primary)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 16)
                .accessibilityIdentifier("summary.collect")
            }
            .frame(maxHeight: 500)
            .sheetSurface()
        }
        .task {
            // "Ask every time" is asked here, once, where the ride is fresh. "Automatically"
            // has already happened on the server by now; "Never" shows nothing.
            if container.session.settings.stravaUploadMode == .ask, summary.ride.stravaUploadStatus == nil,
               let status = try? await container.api.stravaStatus(), status.connected {
                offerStrava = true
            }
        }
        .task {
            geometry = try? await container.api.rideGeometry(id: summary.ride.id)
            if let path = geometry?.path, path.count >= 2 {
                camera = MapCamera(fit: path, padding: UIEdgeInsets(top: 70, left: 40, bottom: 110, right: 40))
            }
        }
        .onAppear {
            guard animated else { return showEverything() }
            reveal = Task { await playReveal() }
        }
        .onDisappear { reveal?.cancel() }
    }

    // MARK: The reveal

    private func playReveal() async {
        traceShown = 0
        // The line of the ride, drawn from its start.
        for step in 1...24 {
            try? await Task.sleep(for: .milliseconds(55))
            guard !Task.isCancelled else { return }
            traceShown = Double(step) / 24
        }
        if !fights.isEmpty {
            await arrive(at: .fight, after: 0.2)
            // Felt, not tapped on the wrist: a swell for a creature defeated, a knock for one that got away.
            if fights.contains(where: \.seenOff) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7)
            }
            try? await Task.sleep(for: .milliseconds(900))
        }
        if summary.legend != nil || summary.legendWoke != nil {
            await arrive(at: .legend, after: 0.3)
        }
        if let legend = summary.legend {
            // A swell for a phase broken, a swell and three knocks for a legend defeated (0.8.0).
            if let haptic = SignatureHaptic.forLegend(legend) {
                SignatureHapticsPlayer.shared.play(haptic)
                try? await Task.sleep(for: .milliseconds(1600))
            } else {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.8)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        await arrive(at: .xp, after: 0.1) {
            withAnimation(.easeOut(duration: 1.1)) {
                shownXP = Double(summary.xpAwarded)
                levelFill = 1
            }
        }
        if !xpLines.isEmpty {
            await arrive(at: .lines, after: 1.1)
            for count in 1...xpLines.count {
                try? await Task.sleep(for: .milliseconds(170))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.25)) { linesShown = count }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
            }
        }
        if coins > 0 {
            await arrive(at: .coins, after: 0.45) {
                withAnimation(.easeOut(duration: 0.9)) { shownCoins = Double(coins) }
            }
        }
        if !summary.levelUps.isEmpty || !summary.abilitiesUnlocked.isEmpty || !(summary.titlesUnlocked ?? []).isEmpty {
            await arrive(at: .levels, after: 0.9)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            container.rideAudio.play(.questDone)
            try? await Task.sleep(for: .milliseconds(700))
        }
        if hasWorld { await arrive(at: .world, after: 0.5) }
        if hasDistricts {
            await arrive(at: .districts, after: 0.5)
            // A district made yours or completed is a celebration; new tiles alone are not.
            if !summary.districtsMadeYours.isEmpty || !summary.districtsCompleted.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
        if let lair = summary.lair {
            await arrive(at: .lair, after: 0.5)
            // The great chest opens: two knocks and a rattle.
            if lair.done { SignatureHapticsPlayer.shared.play(.chest) } else { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            try? await Task.sleep(for: .milliseconds(lair.done ? 900 : 300))
        }
        if !summary.treasures.isEmpty {
            await arrive(at: .treasure, after: 0.5)
            SignatureHapticsPlayer.shared.play(.chest)
            try? await Task.sleep(for: .milliseconds(900))
        }
        if !firsts.isEmpty {
            await arrive(at: .codex, after: 0.5)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        if !runeLines.isEmpty {
            await arrive(at: .runes, after: 0.5)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
        if !finds.isEmpty {
            await arrive(at: .items, after: 0.5)
            // A Rare or Legendary find shimmers (0.8.0); anything else is a plain success.
            if let rare = finds.first(where: { SignatureHaptic.forFind(rarity: $0.rarity) != nil }) {
                SignatureHapticsPlayer.shared.play(find: rare.rarity)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        if hasQuest { await arrive(at: .quest, after: 0.6) }
        if summary.entryToRead?.isEmpty == false { await arrive(at: .entry, after: 0.5) }
        await arrive(at: .rest, after: 0.6)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func arrive(at next: Stage, after seconds: Double, _ also: () -> Void = {}) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        guard !Task.isCancelled else { return }
        withAnimation(.snappy(duration: 0.4)) { stage = next }
        also()
    }

    /// One tap: no waiting, everything there.
    private func showEverything() {
        reveal?.cancel()
        traceShown = 1
        shownXP = Double(summary.xpAwarded)
        shownCoins = Double(coins)
        levelFill = 1
        linesShown = xpLines.count
        withAnimation(.snappy(duration: 0.3)) { stage = .rest }
    }

    private var drawnTrace: [Coordinate] {
        guard let path = geometry?.path, path.count >= 2 else { return [] }
        return Array(path.prefix(max(2, Int(Double(path.count) * traceShown))))
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: LoreCopy.journeysEnd, color: Theme.Colors.sageDeep)
                Text(summary.quest?.title ?? summary.ride.title ?? LoreCopy.free(summary.ride.activity))
                    .font(Theme.Typography.voice(28, relativeTo: .title))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                CountingText(value: shownXP, prefix: "+").font(Theme.Typography.text(40, .bold, relativeTo: .largeTitle))
                Text("XP").font(Theme.Typography.text(14, .semibold))
            }
            .foregroundStyle(Theme.Colors.sageDeep)
            .opacity(stage >= .xp ? 1 : 0.25)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(summary.xpAwarded) XP")
            .accessibilityIdentifier("summary.xp")
        }
    }

    /// The level as it stands now, filling from where it stood before the ride.
    private func levelBar(_ character: Character) -> some View {
        let after = character.overallLevelProgress
        let levelled = summary.levelUps.contains { $0.kind == .overall }
        let span = Double(max(1, (character.nextOverallLevelXP ?? character.overallXP) - character.overallLevelFloorXP))
        let before = levelled ? 0 : max(0, after - Double(summary.xpAwarded) / span)
        let shown = before + (after - before) * levelFill
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Colors.surface)
                    Capsule().fill(Theme.Colors.sageDeep).frame(width: max(6, geometry.size.width * shown))
                }
            }
            .frame(height: 8)
            HStack {
                Text("Level \(character.overallLevel)").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                Spacer()
                if let next = character.nextOverallLevelXP {
                    Text("\((next - character.overallXP).formatted()) XP to level \(character.overallLevel + 1)")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
            }
        }
        .transition(.opacity)
        .accessibilityIdentifier("summary.levelBar")
    }

    /// The lines of a breakdown, each arriving in turn.
    private func breakdown(_ lines: [(String, String)]) -> some View {
        VStack(spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if index < linesShown || !animated {
                    HStack {
                        Text(line.0).foregroundStyle(Theme.Colors.inkSoft)
                        Spacer()
                        Text(line.1).fontWeight(.semibold).foregroundStyle(Theme.Colors.sageDeep).monospacedDigit()
                    }
                    .font(Theme.Typography.text(14))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .accessibilityIdentifier("summary.xpBreakdown")
    }

    private var coinSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    MarkView(.coin).frame(width: 16, height: 16)
                    CountingText(value: shownCoins, prefix: "+", suffix: shownCoins == 1 ? " coin" : " coins").font(Theme.Typography.text(17, .bold))
                }
                .foregroundStyle(Theme.Colors.terracottaDeep)
                Text(summary.walletBalance.map { "\($0.formatted()) in your purse" } ?? "earned")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            .accessibilityIdentifier("summary.coins")
            if !coinLines.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(coinLines.enumerated()), id: \.offset) { _, line in
                        Text("\(RewardCopy.coins(kind: line.kind)) +\(line.ac)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.inkSoft)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.Colors.surface, in: Capsule())
                    }
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// A level gained is the thing people ride for: it gets a card, not a chip.
    @ViewBuilder
    private var levelCards: some View {
        ForEach(Array(summary.levelUps.enumerated()), id: \.offset) { _, levelUp in
            HStack(spacing: 14) {
                Text("\(levelUp.to)")
                    .font(Theme.Typography.text(34, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.Colors.cream)
                    .frame(width: 62, height: 62)
                    .background(Theme.Colors.sageDeep, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: "Level up!", color: Theme.Colors.sageLight)
                    Text(levelUp.kind == .classLevel ? LoreCopy.classLevel(className, levelUp.to) : "Level \(levelUp.to)")
                        .font(Theme.Typography.voice(22, relativeTo: .title2)).foregroundStyle(Theme.Colors.cream)
                    Text("up from \(levelUp.from)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.line)
                    // What the level gave (0.7.2): "Lantern slot opens", "2 lamps".
                    if let rewards = levelUp.rewards, !rewards.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(rewards.enumerated()), id: \.offset) { _, reward in
                                LevelRewardLine(reward: reward, textColor: Theme.Colors.cream)
                            }
                        }
                        .padding(.top, 6)
                        .accessibilityIdentifier("summary.levelRewards")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("summary.levelUp")
        }
        let gains = summary.abilitiesUnlocked.map { LoreCopy.newSkill($0.name) } + (summary.titlesUnlocked ?? []).map { "New title: \($0)" }
        if !gains.isEmpty { chips(gains) }
    }

    private var hasWorld: Bool {
        if summary.weekNotice?.paid == true || summary.streak?.restTokenUsed == true { return true }
        guard let world = summary.worldObjects else { return summary.streak?.extended == true }
        return !world.claimed.isEmpty || world.missed.contains { $0.reason == "UNBEATEN" } || summary.streak?.extended == true
    }

    /// The districts this journey passed through, and the week's pay (0.9.0).
    private var hasDistricts: Bool { !(summary.districts ?? []).isEmpty || (summary.districtPay?.coins ?? 0) > 0 }

    private var districtsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Districts", color: Theme.Colors.sageDeep)
            ForEach(summary.districts ?? []) { district in
                HStack(alignment: .top, spacing: 10) {
                    MarkView(.icon(.village, spot: district.completed || district.becameYours ? Spot.sage : nil)).frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        if district.completed {
                            Text("\(DistrictCopy.complete) \(district.name)")
                                .font(Theme.Typography.text(15, .bold)).foregroundStyle(Theme.Colors.sageDeep)
                                .accessibilityIdentifier("summary.districtComplete")
                        } else if district.becameYours {
                            Text(DistrictCopy.becameYours(district.name))
                                .font(Theme.Typography.text(15, .bold)).foregroundStyle(Theme.Colors.sageDeep)
                                .accessibilityIdentifier("summary.districtYours")
                        }
                        Text(DistrictCopy.outcome(district))
                            .font(Theme.Typography.text(14, district.completed || district.becameYours ? .regular : .semibold))
                            .foregroundStyle(district.completed || district.becameYours ? Theme.Colors.inkSoft : Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if district.becameYours, !district.completed {
                            Text("It pays coins every week while you keep visiting.")
                                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("summary.district")
            }
            if let pay = summary.districtPay, pay.coins > 0 {
                HStack(spacing: 8) {
                    MarkView(.coin).frame(width: 16, height: 16)
                    Text(DistrictCopy.pay(pay)).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("summary.districtPay")
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.districts")
    }

    /// Creatures met for the first time on this journey: added to the Codex.
    private var firsts: [CodexFirst] { summary.codexFirsts ?? [] }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Added to the Codex", color: Theme.Colors.sageDeep)
            ForEach(firsts) { first in
                HStack(spacing: 10) {
                    MarkView(.icon(.spellBook, spot: .sage)).frame(width: 18, height: 18)
                    Text(first.metAs.map { $0 == first.name ? "First met: \(first.name)" : "First met: \(first.name), as \($0)" } ?? "First met: \(first.name)")
                        .font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                }
            }
        }
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary.codex")
    }

    /// Runes woken and found, and deeds reached or beaten on this journey (0.7.0).
    private var runeLines: [(mark: Mark, text: String)] {
        var out: [(Mark, String)] = []
        for rune in summary.worldObjects?.woken ?? [] {
            out.append((.rune(rune), "\(rune.capitalized) woke: one rank stronger for this journey."))
        }
        for found in summary.runesFound ?? [] {
            // A Hard rune (0.8.0) comes from a legend defeated or a lair's great chest.
            let hard = HardRunes.ids.contains(found.rune.lowercased()) ? " One of the Hard Six." : ""
            out.append((.rune(found.rune), found.new
                ? "New rune: \(found.rune.capitalized)!\(hard)"
                : "\(found.rune.capitalized) rune stone: \(found.shards) toward its next rank."))
        }
        for reached in summary.deeds?.reached ?? [] {
            out.append((.icon(.trophy, spot: .gold), "\(reached.name): \(reached.title ?? "new tier reached")!"))
        }
        for record in summary.deeds?.records ?? [] {
            out.append((.icon(.laurels), "\(record.name): \(Int(record.value.rounded())) \(record.unit), a new record!"))
        }
        return out
    }

    private var runesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(runeLines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    MarkView(line.mark).frame(width: 24, height: 24)
                    Text(line.text)
                        .font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityIdentifier("summary.runes")
    }

    /// The journey's entry: a few written lines, in the Journal too.
    private func entrySection(_ entry: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Journal entry", color: Theme.Colors.muted)
            Text(entry).font(Theme.Typography.text(14)).italic().foregroundStyle(Theme.Colors.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
        .accessibilityIdentifier("summary.entry")
    }

    /// Effort is damage: one report per creature the journey reached, the quarry first.
    private var fights: [FightReport] {
        FightCopy.ordered(summary.worldObjects?.fights ?? [], quarryId: summary.quarryId)
    }

    private var fightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(fights) { report in
                HStack(alignment: .top, spacing: 10) {
                    // The creature's own face, from its species (FightReport.speciesId).
                    MarkView(.token(GameIcon.forSpecies(report.speciesId ?? ""), ring: report.bounty == true ? .gold : nil))
                        .frame(width: 30, height: 30)
                    Text(FightCopy.line(report, units: units))
                        .font(Theme.Typography.text(14, report.seenOff ? .semibold : .regular))
                        .foregroundStyle(report.seenOff ? Theme.Colors.ink : Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("summary.fight")
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// What was defeated, opened and found; what got away and how nearly; the streak.
    @ViewBuilder
    private var worldSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(summary.worldObjects?.claimed ?? []) { taken in
                HStack(spacing: 10) {
                    EncounterGlyph(kind: taken.kind, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(taken.kind == .monster ? "Defeated" : (taken.kind == .chest ? "Opened" : "Found")) \(taken.name)")
                            .font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                        if let standing = taken.setStanding {
                            Text(standing.line).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(LoreCopy.earned(taken.rewardAC)).font(Theme.Typography.text(13, .bold).monospacedDigit()).foregroundStyle(Theme.Colors.terracottaDeep)
                }
            }
            ForEach(summary.worldObjects?.setsCompleted ?? []) { done in
                Label("\(done.name) complete · \(LoreCopy.earned(done.bonusAC))", systemImage: "sparkles")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                    .accessibilityIdentifier("summary.setComplete")
            }
            ForEach((summary.worldObjects?.missed ?? []).filter { $0.kind == .monster && $0.reason == "UNBEATEN" }) { missed in
                Text(RewardCopy.heldOn(missed, units: units))
                    .font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("summary.nearMiss")
            }
            if let notice = summary.weekNotice, notice.paid {
                Label("This week's notice done: \(notice.title)", systemImage: "pin.fill")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                    .accessibilityIdentifier("summary.weekNotice")
            }
            if let streak = summary.streak, streak.extended {
                Label(streakLine(streak), systemImage: "flame.fill")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
            }
            if summary.streak?.restTokenUsed == true {
                HStack(spacing: 8) {
                    MarkView(.icon(.restToken, spot: .sage)).frame(width: 18, height: 18)
                    Text("You missed a day, so a rest token kept your streak going.")
                        .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("summary.restToken")
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Gear and things to use found on this journey (0.7.2); a find the full bag could
    /// not hold was sold where it was found, and says so.
    private var finds: [ItemFound] { summary.itemsFound ?? [] }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: finds.count == 1 ? "Found on this journey" : "Found on this journey · \(finds.count)", color: Theme.Colors.sageDeep)
            ForEach(Array(finds.enumerated()), id: \.offset) { _, found in
                HStack(alignment: .top, spacing: 10) {
                    MarkView(.of(found)).frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(found.name).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
                            RarityTag(rarity: found.rarity)
                        }
                        if let from = Self.from(found) {
                            Text(from).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                        if found.soldOnTheSpot {
                            Text("Sold on the spot: your bag was full. \(LoreCopy.earned(found.soldFor ?? 0))")
                                .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("summary.soldOnTheSpot")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .transition(.scale(scale: 0.95).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.items")
    }

    /// "From Fen Troll", "From a chest", "A quest reward".
    static func from(_ found: ItemFound) -> String? {
        if let name = found.fromName, !name.isEmpty { return "From \(name)" }
        switch found.source?.uppercased() {
        case "MONSTER": return "From a creature"
        case "CHEST": return "From a chest"
        case "QUEST": return "A quest reward"
        case "BOUNTY": return "From the bounty"
        default: return nil
        }
    }

    private var hasQuest: Bool { summary.questCompletion != nil && summary.quest != nil }

    /// A sealed quest's goal, named at last (0.7.3).
    private var sealedGoal: SealedQuest.Goal? {
        (summary.questCompletion?.quest ?? summary.quest).flatMap { SealedQuest.goal(of: $0) }
    }

    private func sealedSection(_ goal: SealedQuest.Goal) -> some View {
        HStack(spacing: 10) {
            MarkView(.icon(GameIcon.named(goal.icon, or: .scroll), spot: .terracotta)).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Eyebrow(text: "The sealed goal", color: Theme.Colors.terracottaDeep)
                Text(goal.title).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
            }
            Spacer(minLength: 0)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("summary.sealedGoal")
    }

    /// The quest's last word, and where it leaves the story.
    @ViewBuilder
    private var questSection: some View {
        if summary.questCompletion != nil, let quest = summary.quest {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quest complete! All \(quest.requiredObjectives.count) objectives done.")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                if let words = summary.questCompletion?.quest.narrative.completion ?? quest.narrative.completion, !words.isEmpty {
                    Text(words).font(Theme.Typography.text(14)).italic().foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("summary.questWords")
                }
                if let standing = summary.questCompletion?.storyProgress {
                    Label(storyLine(standing), systemImage: standing.arcCompleted ? "book.closed.fill" : "book.fill")
                        .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("summary.story")
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var restSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FactTile(value: "\(summary.discoveries.count)", label: summary.discoveries.count == 1 ? "New place" : "New places")
                FactTile(value: formatter.distance(meters: summary.newTerritoryMeters), label: "Newly explored")
                FactTile(value: formatter.distance(meters: max(0, summary.ride.distanceMeters - summary.newRoadsMeters)), label: "Explored before")
            }
            Text("\(formatter.distance(meters: summary.ride.distanceMeters)) · \(formatter.duration(seconds: Double(summary.ride.durationSeconds))) · \(formatter.elevation(meters: summary.ride.elevationGainMeters)) climbed")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.muted)
            if !summary.discoveries.isEmpty { chips(summary.discoveries.map(\.name), tint: Theme.Colors.surface, text: Theme.Colors.ink) }
            if !summary.flags.isEmpty {
                // Never the flags themselves: they are codes, and say nothing a rider can act on.
                Text("Part of this \(LoreCopy.journey(summary.ride.activity)) couldn't be checked, so some of it may not count.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
            }
            if summary.ride.healthKitWorkoutId != nil {
                Label("Saved to Health", systemImage: "heart.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
            }
            stravaLine
            FlowLayout(spacing: 8) {
                // The picture of this journey to send someone (0.7.3).
                Button { sharing = true } label: {
                    Label("Share card", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.surfacePill)
                .accessibilityIdentifier("summary.share")
                .sheet(isPresented: $sharing) { ShareCardSheet(summary: summary) }
                Button { export = .garminActivity(rideId: summary.ride.id, activity: summary.ride.activity) } label: {
                    Label("Save for Garmin", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.surfacePill)
                .accessibilityIdentifier("summary.garmin")
                .sheet(item: $export) { ExportFileSheet(request: $0) }
            }
            if let nudge = comeBackLine {
                Label(nudge, systemImage: "flame.fill")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                    .accessibilityIdentifier("summary.comeBack")
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func chips(_ items: [String], tint: Color = Theme.Colors.sageTint, text: Color = Theme.Colors.sageText) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(tint, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var stravaLine: some View {
        switch stravaState {
        case .sent:
            Label("Sent to Strava", systemImage: "checkmark.circle.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
        case .sending:
            Label("Sending to Strava…", systemImage: "arrow.up.circle").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        case .failed(let reason):
            Text("Couldn't send to Strava. \(reason)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
        case .idle:
            if summary.ride.stravaUploadStatus == "UPLOADED" || summary.ride.stravaUploadStatus == "QUEUED" {
                Label("Sent to Strava", systemImage: "checkmark.circle.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
            } else if offerStrava {
                Button {
                    stravaState = .sending
                    Task {
                        do { _ = try await container.api.uploadRideToStrava(rideId: summary.ride.id); stravaState = .sent }
                        catch { stravaState = .failed(error.localizedDescription) }
                    }
                } label: {
                    Label("Upload to Strava", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.surfacePill)
            }
        }
    }

    // MARK: Words

    private var className: String { ClassStyle.name(character?.characterClass ?? .explorer) }

    /// The places found, and an ink mark where a creature was defeated: the mark of
    /// what did it.
    private var markers: [MapMarker] {
        let places = summary.discoveries.map { MapMarker(id: $0.id.uuidString, coordinate: $0.coordinate, kind: .discovery, title: $0.name) }
        let gone = fights.filter(\.seenOff).compactMap { report in
            report.coordinate.map {
                MapMarker(id: "fight-\(report.id.uuidString)", coordinate: $0, kind: .monster, title: report.name ?? "",
                          mark: .kind(report.finisher ?? "ROAD"))
            }
        }
        return places + (stage >= .fight ? gone : [])
    }

    private var revealLine: String {
        let area = Double(summary.newCells) * Self.cellAreaKm2
        let areaText = area >= 10 ? "\(Int(area.rounded())) km²" : String(format: "%.1f km²", area)
        return "\(areaText) explored · \(summary.newCells) new tile\(summary.newCells == 1 ? "" : "s")"
    }

    private func streakLine(_ streak: StreakOutcome) -> String {
        var line = LoreCopy.streak(streak.days)
        if streak.days > 1, streak.days >= streak.longest { line += ", your longest yet" }
        if streak.milestone != nil { line += " · a milestone!" }
        return streak.bonusAC > 0 ? "\(line) · \(LoreCopy.earned(streak.bonusAC))" : line
    }

    private func storyLine(_ standing: StoryStanding) -> String {
        if standing.arcCompleted {
            var line = "\(standing.arcTitle) complete!"
            if let title = standing.reward?.title { line += " New title: \(title)." }
            return line
        }
        var line = "\(standing.arcTitle) · \(standing.stepsDone) of \(standing.stepsTotal)."
        if let next = standing.nextTitle { line += " Next: \(next)." }
        // A festival's arc (0.9.0) closes with its window.
        if standing.isSeason, !standing.arcCompleted, let ends = standing.closesAt { line += " \(SeasonCopy.ends(ends))." }
        return line
    }

    /// What tomorrow is worth: the next streak bonus, or simply the next day.
    private var comeBackLine: String? {
        guard let streak = summary.streak, streak.days > 0 else { return "Go out again tomorrow to start a streak." }
        if let next = [7, 30].first(where: { $0 > streak.days }) {
            let left = next - streak.days
            return "\(left) more \(left == 1 ? "day" : "days") to a \(LoreCopy.purse(next == 7 ? 100 : 500)) streak bonus. A new bounty comes at dawn."
        }
        return "\(LoreCopy.streak(streak.days)). A new bounty comes at dawn."
    }
}

/// A number that counts to its value when the value is animated to.
struct CountingText: View, Animatable {
    var value: Double
    var prefix = ""
    var suffix = ""

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text("\(prefix)\(Int(value.rounded()).formatted())\(suffix)").monospacedDigit()
    }
}

/// The ride has ended and the server is counting: what the phone itself knows,
/// straight away, where there used to be the tabs and nothing.
struct RideHoldingView: View {
    let pending: PendingReckoning
    let timedOut: Bool
    let units: Units
    let onLeave: () -> Void

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        ZStack {
            Theme.Colors.cream.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                Spacer(minLength: 0)
                Eyebrow(text: "\((pending.activity ?? .ride).verb) saved", color: Theme.Colors.sageDeep)
                Text(pending.title)
                    .font(Theme.Typography.voice(32, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    FactTile(value: formatter.distance(meters: pending.distanceMeters), label: "Distance")
                    FactTile(value: formatter.duration(seconds: pending.elapsedSeconds), label: "Time")
                    FactTile(value: formatter.distance(meters: pending.newTerritoryMeters), label: "Newly explored", valueColor: Theme.Colors.sageDeep)
                }
                if !pending.claimed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pending.claimed, id: \.self) { line in
                            Label(line, systemImage: "checkmark.circle.fill")
                                .font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink)
                        }
                    }
                }
                HStack(spacing: 10) {
                    if !timedOut { ProgressView().tint(Theme.Colors.terracotta) }
                    Text(timedOut ? "Still adding it up. It will be in your Journal when it's ready." : "Adding up your rewards…")
                        .font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
                Button("Keep exploring", action: onLeave)
                    .buttonStyle(.secondaryWide)
                    .accessibilityIdentifier("holding.leave")
                Text("Your rewards will show in the Journal when they're ready.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rideHolding")
    }
}
