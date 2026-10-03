import RoadsAndRunesCore
import SwiftUI

/// Adventure Complete (design 13b): the reckoning.
///
/// The ride's line draws itself on the map, then what it earned arrives a part at
/// a time: the XP counts up and the level fills, each line of it lands, then the
/// coins, then a level gained (its own card), then what was beaten, opened and
/// found — and what got away, and by how much — then the quest's last word. It
/// was one static sheet with a level-up as a small chip among others. One tap
/// shows everything at once; "Close the book" is there from the start. Cycling
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

    private enum StravaLineState { case idle, sending, sent, failed(String) }

    /// The order things arrive in.
    private enum Stage: Int, Comparable {
        case trace, xp, lines, coins, levels, world, quest, rest

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
                            if stage >= .xp, animated, let character { levelBar(character) }
                            if stage >= .lines, !xpLines.isEmpty { breakdown(xpLines.map { (RewardCopy.xp(source: $0.source, className: className), "+\($0.xp)") }).id(Stage.lines) }
                            if stage >= .coins, coins > 0 { coinSection.id(Stage.coins) }
                            if stage >= .levels { levelCards.id(Stage.levels) }
                            if stage >= .world { worldSection.id(Stage.world) }
                            if stage >= .quest { questSection.id(Stage.quest) }
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
                Button(animated ? LoreCopy.closeTheBook : "Done") {
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
        if hasQuest { await arrive(at: .quest, after: 0.6) }
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
                Eyebrow(text: LoreCopy.reckoning, color: Theme.Colors.sageDeep)
                Text(summary.quest?.title ?? summary.ride.title ?? "Free ride")
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
                    Image(systemName: "circlebadge.2.fill").font(.system(size: 13, weight: .bold))
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
                    Eyebrow(text: "Level up", color: Theme.Colors.sageLight)
                    Text(levelUp.kind == .classLevel ? "\(className) level \(levelUp.to)" : "Level \(levelUp.to)")
                        .font(Theme.Typography.voice(22, relativeTo: .title2)).foregroundStyle(Theme.Colors.cream)
                    Text("from \(levelUp.from)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.line)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("summary.levelUp")
        }
        let gains = summary.abilitiesUnlocked.map { LoreCopy.newKnack($0.name) } + (summary.titlesUnlocked ?? []).map { "Title: \($0)" }
        if !gains.isEmpty { chips(gains) }
    }

    private var hasWorld: Bool {
        guard let world = summary.worldObjects else { return summary.streak?.extended == true }
        return !world.claimed.isEmpty || world.missed.contains { $0.reason == "UNBEATEN" } || summary.streak?.extended == true
    }

    /// What was beaten, opened and found; what got away and how nearly; the days in a row.
    @ViewBuilder
    private var worldSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(summary.worldObjects?.claimed ?? []) { taken in
                HStack(spacing: 10) {
                    EncounterGlyph(kind: taken.kind, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(taken.kind == .monster ? "Beat" : (taken.kind == .chest ? "Opened" : "Found")) \(taken.name)")
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
                Text(RewardCopy.shruggedOff(missed, units: units))
                    .font(Theme.Typography.text(13)).foregroundStyle(Theme.Colors.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("summary.nearMiss")
            }
            if let streak = summary.streak, streak.extended {
                Label(streakLine(streak), systemImage: "flame.fill")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var hasQuest: Bool { summary.questCompletion != nil && summary.quest != nil }

    /// The quest's last word, and where it leaves the story.
    @ViewBuilder
    private var questSection: some View {
        if summary.questCompletion != nil, let quest = summary.quest {
            VStack(alignment: .leading, spacing: 6) {
                Text("Quest completed · all \(quest.requiredObjectives.count) objectives")
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
                FactTile(value: formatter.distance(meters: summary.newTerritoryMeters), label: "New territory")
                FactTile(value: formatter.distance(meters: max(0, summary.ride.distanceMeters - summary.newRoadsMeters)), label: "Known ground")
            }
            Text("\(formatter.distance(meters: summary.ride.distanceMeters)) · \(formatter.duration(seconds: Double(summary.ride.durationSeconds))) · \(formatter.elevation(meters: summary.ride.elevationGainMeters)) climbed")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.muted)
            if !summary.discoveries.isEmpty { chips(summary.discoveries.map(\.name), tint: Theme.Colors.surface, text: Theme.Colors.ink) }
            if !summary.flags.isEmpty {
                Text("Some data could not be validated: \(summary.flags.joined(separator: ", "))")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
            }
            if summary.ride.healthKitWorkoutId != nil {
                Label("Saved to Health", systemImage: "heart.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
            }
            stravaLine
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
            Text("Strava: \(reason)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
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

    private var markers: [MapMarker] {
        summary.discoveries.map { MapMarker(id: $0.id.uuidString, coordinate: $0.coordinate, kind: .discovery, title: $0.name) }
    }

    private var revealLine: String {
        let area = Double(summary.newCells) * Self.cellAreaKm2
        let areaText = area >= 10 ? "\(Int(area.rounded())) km²" : String(format: "%.1f km²", area)
        return "\(areaText) revealed · \(summary.newCells) new area\(summary.newCells == 1 ? "" : "s")"
    }

    private func streakLine(_ streak: StreakOutcome) -> String {
        var line = LoreCopy.daysKept(streak.days)
        if streak.days > 1, streak.days >= streak.longest { line += ", your longest yet" }
        if streak.milestone != nil { line += " · a milestone" }
        return streak.bonusAC > 0 ? "\(line) · \(LoreCopy.earned(streak.bonusAC))" : line
    }

    private func storyLine(_ standing: StoryStanding) -> String {
        if standing.arcCompleted {
            var line = "\(standing.arcTitle) is finished."
            if let title = standing.reward?.title { line += " You are \(title) now." }
            return line
        }
        var line = "\(standing.arcTitle) · \(standing.stepsDone) of \(standing.stepsTotal)."
        if let next = standing.nextTitle { line += " Next: \(next)." }
        return line
    }

    /// What tomorrow is worth: the next streak purse, or simply the next day.
    private var comeBackLine: String? {
        guard let streak = summary.streak, streak.days > 0 else { return "Out again tomorrow and the days start to count." }
        if let next = [7, 30].first(where: { $0 > streak.days }) {
            let left = next - streak.days
            return "\(left) more \(left == 1 ? "day" : "days") kept for a purse of \(next == 7 ? 100 : 500). A new bounty is out at dawn."
        }
        return "\(LoreCopy.daysKept(streak.days)). A new bounty is out at dawn."
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
                Eyebrow(text: "Ride saved", color: Theme.Colors.sageDeep)
                Text(pending.title)
                    .font(Theme.Typography.voice(32, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    FactTile(value: formatter.distance(meters: pending.distanceMeters), label: "Ridden")
                    FactTile(value: formatter.duration(seconds: pending.elapsedSeconds), label: "Time")
                    FactTile(value: formatter.distance(meters: pending.newTerritoryMeters), label: "New ground", valueColor: Theme.Colors.sageDeep)
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
                    Text(timedOut ? "Still counting. It will be in your Journal when it is done." : "Counting the spoils. The server has the last word.")
                        .font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
                Button("Carry on", action: onLeave)
                    .buttonStyle(.secondaryWide)
                    .accessibilityIdentifier("holding.leave")
                Text("The reckoning will find you when it is ready.")
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
