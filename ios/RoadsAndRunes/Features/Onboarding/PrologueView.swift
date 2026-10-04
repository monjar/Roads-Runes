import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The premise in four plates (docs/WORLD.md), before a trade is chosen. The same
/// plates open once for a player who already has a character, and again from
/// the codex's first page. Nothing to do on them but read and go on.
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
        Plate(mark: .rune("raido"), line: "Every road was written once.",
              more: "The people who made them cut a rune where two ways met, and the rune said what the road was for."),
        Plate(mark: .kind("GROUND"), line: "People still use the roads. Nobody reads them.",
              more: "A road that is used and not read goes vague. That is the fog."),
        Plate(mark: .creature(Sigil(body: "hulk", feature: "horns", mark: "water")), line: "Things settle in the vague parts.",
              more: "Small, local, with habits. None of them is in charge."),
        Plate(mark: .crest("explorer"), line: "You read.",
              more: "Go out, and the roads are read again. What you have read goes in the book, and the book does not forget."),
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
                Button(page == Self.plates.count - 1 ? finish : "On") {
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

/// Shown once, to a player who had a character before the world had a premise.
enum Prologue {
    static let seenKey = "prologue.seen.v1"

    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }
}
