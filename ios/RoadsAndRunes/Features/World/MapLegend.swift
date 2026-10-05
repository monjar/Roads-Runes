import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// What every mark on the map is and what to do with it, drawn with the marks
/// themselves (docs/ROADMAP.md, 0.7.1). Opened from the "?" among the map's
/// buttons; nothing on the map explained itself before.
struct MapLegend: View {
    @Environment(\.dismiss) private var dismiss

    struct Entry: Identifiable {
        let mark: Mark
        let name: String
        let what: String
        var id: String { name }
    }

    static let entries: [Entry] = [
        Entry(mark: .rider("RIDE"), name: "You", what: "Where you are now."),
        Entry(mark: .creature(Sigil(body: "hulk", feature: "horns", mark: "water")), name: "Creature",
              what: "Ride near it to defeat it. Tap it to see what it is weak to."),
        Entry(mark: .creature(Sigil(body: "wyrm", feature: "wings", mark: "wall"), bounty: true), name: "Bounty",
              what: "Today's bounty: a creature worth double coins."),
        Entry(mark: .creature(Sigil(body: "beast", feature: "antlers", mark: "mist"), tier: 3), name: "Elder",
              what: "A stronger creature with a bigger reward. Two rings, or a crown for the strongest."),
        Entry(mark: .legend(icon: "fogDragon"), name: "Legend",
              what: "A great creature that takes several journeys. Tap it to see its health and what it is weak to."),
        Entry(mark: .lair, name: "Lair", what: "Seven tiles round a park. Visit five of them in time to open its great chest."),
        Entry(mark: .chest(tier: 1), name: "Chest", what: "Get close, then tap Open for coins."),
        Entry(mark: .rune("raido"), name: "Rune stone", what: "Get close and pick it up to collect its rune."),
        Entry(mark: .quest, name: "Quest", what: "A quest from the board. Tap it to read it."),
        Entry(mark: .objective, name: "Objective", what: "Where a quest wants you to go."),
        Entry(mark: .mystery, name: "Hidden place", what: "Ride past it to find out what it is."),
        Entry(mark: .place("PUB"), name: "Place", what: "A pub, café, park or landmark. Tap to ride there or light a lamp."),
        Entry(mark: .lamp, name: "Lamp", what: "Lit at a place, it calls a creature there for 50 coins."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Self.entries) { entry in
                        HStack(spacing: 14) {
                            MarkView(entry.mark).frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
                                Text(entry.what).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .listRowBackground(Theme.Colors.surface)
                    }
                }
                Section("Tips") {
                    Text("Press and hold anywhere on the map to drop a pin and ride there.")
                    Text("The orange button plans a ride from where you are.")
                    Text("Rune shapes you have ridden stay drawn on the map.")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.inkSoft)
                .listRowBackground(Theme.Colors.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.cream)
            .navigationTitle("On the map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("legend.done")
                }
            }
        }
        .accessibilityIdentifier("mapLegend")
    }
}
