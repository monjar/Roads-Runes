import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Runes as the build (docs/ROADMAP.md, 0.7.0): the slots the level has opened,
/// what is inscribed in them, every rune held with its rank, its rune stones and what
/// it does, and a way to go and ride its shape. Only inscribed runes work.
struct RunesScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var state: RunesState?
    @State private var error: String?
    @State private var busy: String?
    @State private var cutting: String?
    /// The server has no runes (one from before 0.7.0): say so, not a spinner for ever.
    @State private var missing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if missing {
                    EmptyState(icon: .runeStone, title: "Runes aren't here yet", message: "They arrive with the next server update.")
                } else if let error {
                    ErrorLine(text: error)
                }
                if missing {
                    EmptyView()
                } else if let state {
                    slots(state)
                    let held = state.runes.filter(\.held)
                    if held.isEmpty {
                        EmptyState(icon: .runeStone, title: "No runes yet",
                                   message: "Rune stones turn up at places on the map. Pick one up and its rune is yours.")
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("runes.empty")
                    } else {
                        SectionHeader(title: "Your runes", subtitle: "\(held.count) of \(state.runes.count)")
                        ForEach(held) { rune in row(rune, state: state) }
                    }
                    let ahead = state.runes.filter { !$0.held }
                    if !ahead.isEmpty {
                        SectionHeader(title: "Still to find")
                        ForEach(ahead) { rune in row(rune, state: state) }
                    }
                } else {
                    ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                }
            }
            .padding(22)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("Runes")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: Binding(get: { cutting.map(RuneChoice.init) }, set: { cutting = $0?.id })) { choice in
            RoutePlannerView(quest: nil, rune: choice.id)
        }
    }

    private struct RuneChoice: Identifiable { let id: String }

    /// Loops, triangles and squares are ridden on a bike; a zigzag is run or walked.
    static func cutForms(for activity: Activity) -> Set<String> {
        activity == .run || activity == .walk ? ["ZIGZAG"] : ["LOOP", "TRIANGLE", "SQUARE"]
    }

    @ViewBuilder
    private func slots(_ state: RunesState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Inscribed", color: Theme.Colors.terracottaDeep)
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { index in
                    let open = index < state.slots
                    let runeId = index < state.inscribed.count ? state.inscribed[index] : nil
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Theme.Colors.ink.opacity(open ? 0.35 : 0.12), style: StrokeStyle(lineWidth: 1.2, dash: open ? [] : [3, 3]))
                        if let runeId {
                            MarkView(.rune(runeId)).frame(width: 40, height: 40)
                        } else if !open {
                            Text("Level \(state.slotsAtLevel[index])").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(runeId.map { "Slot \(index + 1): \($0.capitalized)" } ?? (open ? "Slot \(index + 1): empty" : "Slot \(index + 1): opens at level \(state.slotsAtLevel[index])"))
                }
            }
            Text("Only inscribed runes work. Swap them for free any time you're not on a journey.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runes.slots")
    }

    private func row(_ rune: RuneInfo, state: RunesState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                MarkView(.rune(rune.id)).frame(width: 40, height: 40).opacity(rune.held ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(rune.name).font(Theme.Typography.text(16, .semibold)).foregroundStyle(Theme.Colors.ink)
                        if rune.held { Text(LoreCopy.roman(rune.rank)).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep) }
                        if rune.inscribed { Eyebrow(text: "Inscribed", color: Theme.Colors.sageDeep) }
                    }
                    if let gloss = rune.gloss { Text(gloss).font(Theme.Typography.caption).italic().foregroundStyle(Theme.Colors.muted) }
                    Text(rune.rule).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    if !rune.held, rune.six == "GROUND" {
                        Text("Found only near \(Self.ground(of: rune.id)).").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    if rune.held, let next = rune.nextRank {
                        Text("\(rune.shards) / \(next.shards) rune stones to rank \(LoreCopy.roman(rune.rank + 1)) · \(LoreCopy.purse(next.coins))")
                            .font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            if rune.held {
                HStack(spacing: 8) {
                    Button(rune.inscribed ? "Remove rune" : "Inscribe rune") { Task { await toggle(rune, state: state) } }
                        .buttonStyle(.surfacePill)
                        .disabled(busy != nil || (!rune.inscribed && state.inscribed.count >= state.slots))
                        .accessibilityIdentifier("rune.\(rune.id).inscribe")
                    if rune.canRaise {
                        Button("Rank up") { Task { await raise(rune) } }
                            .buttonStyle(.surfacePill)
                            .disabled(busy != nil)
                    }
                    if let form = rune.roadForm, Self.cutForms(for: container.session.defaultActivity).contains(form) {
                        Button("\(container.session.defaultActivity.verb) its shape") { cutting = rune.id }
                            .buttonStyle(.surfacePill)
                            .accessibilityIdentifier("rune.\(rune.id).cut")
                    }
                    if busy == rune.id { ProgressView().tint(Theme.Colors.terracotta) }
                }
            }
        }
        .card()
        .accessibilityIdentifier("rune.\(rune.id)")
    }

    /// Where a Ground Six rune's stones turn up (backend inventory/config/runes.json, `ground`).
    static func ground(of rune: String) -> String {
        switch rune {
        case "laguz": return "water"
        case "berkano": return "parks, gardens and woods"
        case "eihwaz": return "old and historic places"
        case "ehwaz": return "cycleways and bike shops"
        case "jera": return "farms, orchards and allotments"
        case "algiz": return "viewpoints and peaks"
        default: return "its own kind of place"
        }
    }

    private func load() async {
        do {
            state = try await container.api.runes()
            error = nil
        } catch let failure as APIError where failure.isNotFound {
            missing = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func toggle(_ rune: RuneInfo, state: RunesState) async {
        busy = rune.id
        defer { busy = nil }
        let next = rune.inscribed ? state.inscribed.filter { $0 != rune.id } : state.inscribed + [rune.id]
        do {
            self.state = try await container.api.inscribe(runes: next)
            error = nil
            await container.session.refreshCharacter()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func raise(_ rune: RuneInfo) async {
        busy = rune.id
        defer { busy = nil }
        do {
            state = try await container.api.raiseRune(id: rune.id)
            error = nil
            await container.session.refreshCharacter()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The five deeds and the three records, on the sheet (0.7.0): a record of what has
/// been done, not points to spend. Each deed wears the mark of its kind of effort.
struct DeedsCard: View {
    @Environment(AppContainer.self) private var container
    @State private var deeds: DeedsState?
    /// The server could not say (one from before 0.7.0 has no deeds): not a spinner for ever.
    @State private var unavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let deeds {
                ForEach(deeds.deeds) { deed in
                    HStack(spacing: 12) {
                        MarkView(.kind(Self.kind(of: deed.id))).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(deed.name).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
                                if let title = deed.title { Text(title).font(Theme.Typography.caption).italic().foregroundStyle(Theme.Colors.terracottaDeep) }
                            }
                            Text(line(deed)).font(Theme.Typography.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 3) {
                            ForEach(0..<5, id: \.self) { tier in
                                Circle().fill(tier < deed.tier ? Theme.Colors.terracottaDeep : Theme.Colors.line).frame(width: 6, height: 6)
                            }
                        }
                        .accessibilityLabel("\(deed.tier) of 5")
                    }
                }
                Divider().overlay(Theme.Colors.line)
                ForEach(deeds.records) { record in
                    HStack {
                        Text(record.name).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.inkSoft)
                        Spacer()
                        Text(record.value.map { format($0, record.unit) } ?? "—")
                            .font(Theme.Typography.captionStrong.monospacedDigit()).foregroundStyle(Theme.Colors.ink)
                    }
                }
            } else if unavailable {
                Text("Couldn't load your deeds. Check your connection and try again later.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            } else {
                ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
            }
        }
        .card()
        .accessibilityIdentifier("character.deeds")
        .task {
            deeds = try? await container.api.deeds()
            unavailable = deeds == nil
        }
    }

    static func kind(of deed: String) -> String {
        switch deed {
        case "LEGS": return "ROAD"
        case "LUNGS": return "CLIMB"
        case "EYES": return "GROUND"
        case "HAND": return "RUNE"
        default: return "WORD"
        }
    }

    private func line(_ deed: DeedsState.Deed) -> String {
        let now = format(deed.value, deed.unit)
        guard let next = deed.next else { return "\(now) · every tier reached" }
        return "\(now) · next at \(format(next, deed.unit))"
    }

    private func format(_ value: Double, _ unit: String) -> String {
        let number = value >= 100 || value == value.rounded() ? "\(Int(value.rounded()).formatted())" : String(format: "%.1f", value)
        return "\(number) \(unit)"
    }
}
