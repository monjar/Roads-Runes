import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// How to play, in five pages, before a class is chosen (docs/VOICE.md): what
/// there is to do and how, each with the mark the player will meet on the map.
/// The same pages open once for a player who already has a character, and again
/// from Settings and the Codex. It replaced four plates of premise that never
/// said what to do.
struct PrologueView: View {
    let finish: String
    let onDone: () -> Void
    @State private var page = 0

    struct Plate {
        let mark: Mark
        let line: String
        let more: String
    }

    static let plates: [Plate] = [
        Plate(mark: .rider("RIDE"), line: "Ride real roads.",
              more: "Plan a ride, a run or a walk from the map. Everything in the game waits on real streets near you."),
        Plate(mark: .chest(tier: 2), line: "Open chests. Gather rune stones.",
              more: "Chests and rune stones sit at real places on the map. Get close, then tap to open or pick up. Chests are full of coins."),
        Plate(mark: .creature(Sigil(body: "hulk", feature: "horns", mark: "water")), line: "Defeat creatures by riding.",
              more: "Creatures wait at parks, pubs and landmarks. Ride near one and every kilometre, hill and new street wears it down. Tap one to see what it is weak to."),
        Plate(mark: .quest, line: "Take quests from the board.",
              more: "Quests send you somewhere new for coins and XP. Today's bounty is a creature worth double."),
        Plate(mark: .crest("wizard"), line: "Grow your character.",
              more: "Level up to learn skills and earn titles. Inscribe runes for their powers. Spend coins on lamps to call a creature to a place you choose."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(Self.plates.enumerated()), id: \.offset) { index, plate in
                    VStack(spacing: 22) {
                        Spacer()
                        MarkView(plate.mark).frame(width: 150, height: 150)
                        Text(plate.line)
                            .font(Theme.Typography.voice(28, relativeTo: .title))
                            .foregroundStyle(Theme.Colors.ink)
                            .multilineTextAlignment(.center)
                        Text(plate.more)
                            .font(Theme.Typography.text(15))
                            .foregroundStyle(Theme.Colors.muted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                        Spacer()
                    }
                    .padding(.horizontal, 32)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            HStack {
                Button("Skip", action: onDone)
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(Theme.Colors.muted)
                    .accessibilityIdentifier("prologue.skip")
                Spacer()
                Button(page == Self.plates.count - 1 ? finish : "Next") {
                    if page == Self.plates.count - 1 { onDone() } else { withAnimation(.snappy) { page += 1 } }
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("prologue.next")
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
        .background(Theme.Colors.cream.ignoresSafeArea())
    }
}

/// Shown once to a player who already had a character: v2 is how to play, which
/// replaced the premise plates every earlier player had seen (v1).
enum Prologue {
    static let seenKey = "prologue.seen.v2"

    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }
}
