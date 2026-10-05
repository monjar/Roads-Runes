import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The Codex (docs/WORLD.md): what the world is, the creatures in it, the runes,
/// the people who write the board, and the places found. It lives in
/// the Journal; the character sheet opens the same pages.
struct CodexBrowser<Places: View>: View {
    @Environment(AppContainer.self) private var container
    let codex: Codex?
    /// Fights by effort are on: a creature's page says what it is weak to.
    let showWants: Bool
    @ViewBuilder let places: () -> Places
    @State private var chapter = "WORLD"
    @State private var showingPrologue = false

    private static var chapters: [(id: String, title: String)] {
        [("WORLD", "The world"), ("CREATURES", "Creatures"), ("LEGENDS", "Legends"), ("RUNES", "Runes"), ("PEOPLE", "People"),
         ("PLACES", "Places")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.chapters, id: \.id) { item in
                        FilterChip(text: item.title, selected: chapter == item.id) { chapter = item.id }
                            .accessibilityIdentifier("codex.chapter.\(item.id.lowercased())")
                    }
                }
            }
            if chapter == "PLACES" {
                places()
            } else if chapter == "LEGENDS" {
                legends()
            } else if let codex {
                switch chapter {
                case "CREATURES": creatures(codex)
                case "RUNES": runes(codex)
                case "PEOPLE": people(codex)
                default: world(codex)
                }
            } else {
                ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: The world

    @ViewBuilder
    private func world(_ codex: Codex) -> some View {
        Button { showingPrologue = true } label: { Label("Read the prologue", systemImage: "book.pages") }
            .buttonStyle(.surfacePill)
            .sheet(isPresented: $showingPrologue) {
                PrologueView(finish: "Close") { showingPrologue = false }
            }
        ForEach(codex.entries(in: "WORLD")) { entry in
            CodexPageCard(title: entry.title, paragraphs: entry.body, byline: entry.byName)
        }
    }

    // MARK: Creatures

    @ViewBuilder
    private func creatures(_ codex: Codex) -> some View {
        Text("Defeated \(codex.counts.creaturesSeenOff) of \(codex.counts.creaturesTotal) · seen \(codex.counts.creaturesSeen)")
            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            .accessibilityIdentifier("codex.creatures.count")
        if codex.creatures.allSatisfy({ $0.state == .unseen }) {
            EmptyState(icon: .mystery, title: "No creatures met yet", message: "Get close to one on the map to add it here.")
        }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
            ForEach(codex.creatures) { creature in
                NavigationLink { CreaturePage(creature: creature, runes: codex.runes, showWants: showWants) } label: {
                    CreatureTile(creature: creature)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("codex.creature")
            }
        }
    }

    // MARK: Legends (0.8.0)

    /// The legend awake and those defeated, each with its page. The server keeps them, not the codex.
    @ViewBuilder
    private func legends() -> some View {
        let store = container.legends
        let met = store.state?.met ?? []
        Text("Defeated \(store.defeated.count) · met \(met.count)")
            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            .accessibilityIdentifier("codex.legends.count")
            .task { if store.state == nil { await store.refresh() } }
        if met.isEmpty {
            EmptyState(icon: .fogDragon, title: "No legends met yet",
                       message: store.state?.creaturesUntilNext.map(LegendCopy.untilNext) ?? "Defeat creatures and a legend will wake.")
        }
        ForEach(met) { legend in
            NavigationLink { LegendCodexPage(legend: legend) } label: {
                HStack(spacing: 12) {
                    MarkView(.of(legend)).frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(legend.name).font(Theme.Typography.text(16, .semibold)).foregroundStyle(Theme.Colors.ink)
                        Text(legend.status == LegendStatus.defeated ? "Defeated" : (legend.status == LegendStatus.dormant ? "Asleep" : "Awake now"))
                            .font(Theme.Typography.caption).foregroundStyle(legend.status == LegendStatus.defeated ? Theme.Colors.sageDeep : Theme.Colors.terracottaDeep)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Colors.muted)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("codex.legend")
        }
    }

    // MARK: Runes

    @ViewBuilder
    private func runes(_ codex: Codex) -> some View {
        Text("\(codex.counts.runesHeld) of \(codex.counts.runesTotal) found")
            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        ForEach(codex.sixes) { six in
            let inSix = codex.runes.filter { $0.six == six.id }.sorted { $0.order < $1.order }
            if !inSix.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(six.name.prefix(1).uppercased() + six.name.dropFirst()).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                    Text(six.how).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                        ForEach(inSix) { rune in
                            NavigationLink { RunePage(rune: rune, six: six) } label: { RuneTile(rune: rune) }
                                .buttonStyle(.pressable)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: People

    @ViewBuilder
    private func people(_ codex: Codex) -> some View {
        ForEach(codex.people) { person in
            VStack(alignment: .leading, spacing: 6) {
                Text(person.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                Eyebrow(text: person.role, color: Theme.Colors.terracottaDeep)
                Text(person.page).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft)
                if let line = person.lines.first {
                    Text("“\(line)”").font(Theme.Typography.caption.italic()).foregroundStyle(Theme.Colors.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        ForEach(codex.entries(in: "PEOPLE")) { entry in
            CodexPageCard(title: entry.title, paragraphs: entry.body, byline: entry.byName,
                          mark: entry.characterClass.flatMap { Mark.crest(CharacterClass.lenient($0)) })
        }
    }
}

/// One page of the codex, signed.
struct CodexPageCard: View {
    let title: String
    let paragraphs: [String]
    let byline: String
    var mark: Mark?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let mark { MarkView(mark).frame(width: 40, height: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("— \(byline)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct CreatureTile: View {
    let creature: CodexCreature

    var body: some View {
        VStack(spacing: 6) {
            MarkView(.creature(Sigil(creature.sigil), unmet: creature.state == .unseen))
                .frame(width: 72, height: 72)
                .opacity(creature.state == .unseen ? 0.55 : 1)
            Text(creature.state == .unseen ? "Not yet seen" : creature.name)
                .font(Theme.Typography.captionStrong)
                .foregroundStyle(creature.state == .unseen ? Theme.Colors.muted : Theme.Colors.ink)
                .lineLimit(2).multilineTextAlignment(.center)
            if creature.seenOffCount > 0 {
                Text("defeated \(creature.seenOffCount)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
            } else if creature.state == .unseen {
                Text(creature.hint).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.mutedLight)
                    .lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct RuneTile: View {
    let rune: CodexRune

    var body: some View {
        VStack(spacing: 6) {
            MarkView(.rune(rune.id)).frame(width: 60, height: 60).opacity(rune.state == .held ? 1 : 0.35)
            Text(rune.name).font(Theme.Typography.captionStrong).foregroundStyle(rune.state == .held ? Theme.Colors.ink : Theme.Colors.muted)
            if rune.state != .held, let legend = HardRunes.leftBy[rune.id] {
                // A Hard rune is findable now: who leaves it (0.8.0).
                Text("from \(legend.name)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.mutedLight)
                    .lineLimit(2).multilineTextAlignment(.center)
            } else if rune.state != .held, rune.id == "ingwaz" {
                Text("from a lair").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.mutedLight)
            }
            if rune.found > 1 {
                Text("found \(rune.found)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(rune.state == .held ? "Found" : "Not yet found")
    }
}

/// A creature's page: its face, what Enid Sallow knows of it, its elders.
struct CreaturePage: View {
    let creature: CodexCreature
    let runes: [CodexRune]
    let showWants: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    MarkView(.creature(Sigil(creature.sigil), unmet: creature.state == .unseen), label: creature.name)
                        .frame(width: 160, height: 160)
                    Spacer()
                }
                Text(creature.state == .unseen ? "Not yet seen" : creature.name)
                    .font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                if creature.state == .unseen {
                    Text(creature.hint).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft)
                } else {
                    Text(creature.page).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("— Enid Sallow").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    if showWants {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LoreCopy.weakTo(creature.wants))
                            if !creature.minds.isEmpty { Text(LoreCopy.resists(creature.minds)) }
                            if let runeName { Text(LoreCopy.runeHow(runeName, form: runeForm)) }
                        }
                        .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                    }
                    facts
                    elders
                }
            }
            .padding(22)
        }
        .background(Theme.Colors.cream)
        .navigationTitle(creature.state == .unseen ? "" : creature.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var runeName: String? { runes.first { $0.id == creature.rune }?.name ?? creature.rune?.capitalized }
    private var runeForm: String? { runes.first { $0.id == creature.rune }?.roadForm }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FactTile(value: "\(creature.seenCount)", label: "Seen")
                FactTile(value: "\(creature.seenOffCount)", label: "Defeated")
                FactTile(value: creature.leaves.capitalizedFirst, label: "Leaves")
            }
            // What it has left behind, counted (0.7.2): "Left behind: a green scale ×3".
            if let trophies = creature.trophies, trophies.count >= 1 {
                HStack(spacing: 8) {
                    MarkView(.icon(.trophy, spot: .gold)).frame(width: 18, height: 18)
                    Text(trophies.line).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("codex.trophies")
            }
        }
    }

    @ViewBuilder
    private var elders: some View {
        SectionHeader(title: "Elders")
        ForEach(creature.elders, id: \.tier) { elder in
            HStack(spacing: 12) {
                MarkView(.creature(Sigil(creature.sigil), tier: elder.tier, unmet: !elder.seen)).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(elder.seen ? elder.name : "Not yet seen").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                    if elder.seen, !elder.flavour.isEmpty {
                        Text(elder.flavour).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                }
            }
        }
    }
}

/// A rune's page: the stone, what it means, and the shape that uses it.
struct RunePage: View {
    let rune: CodexRune
    let six: CodexSix

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    MarkView(.rune(rune.id), label: rune.name).frame(width: 150, height: 150).opacity(rune.state == .held ? 1 : 0.45)
                    Spacer()
                }
                Text(rune.name).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                Eyebrow(text: six.name, color: Theme.Colors.terracottaDeep)
                Text(rune.gloss).font(Theme.Typography.body).foregroundStyle(Theme.Colors.inkSoft)
                if let action = LoreCopy.shapeAction(rune.roadForm) {
                    Text("To use it: \(action.lowercased()) near a creature.").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                }
                Text(rune.state == .held ? (rune.found > 1 ? "Found \(rune.found) times." : "Found once.") : six.how)
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                // The Hard Six can be found now (0.8.0): which legend leaves each, and the lair's chest.
                if rune.state != .held, let how = HardRunes.howToFind(rune.id) {
                    Text(how).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.ink)
                        .accessibilityIdentifier("codex.rune.howToFind")
                }
            }
            .padding(22)
        }
        .background(Theme.Colors.cream)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The codex on its own, opened from the character sheet.
struct CodexScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var codex: Codex?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error { ErrorLine(text: error) }
                CodexBrowser(codex: codex, showWants: container.session.isEnabled("effort_combat")) {
                    Text("The places you have found are in the Journal.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
            }
            .padding(22)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("Codex")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { codex = try await container.api.codex() } catch { self.error = error.localizedDescription }
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
