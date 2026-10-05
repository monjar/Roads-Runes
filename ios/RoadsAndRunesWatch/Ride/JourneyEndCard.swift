import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Journey's end on the wrist (0.7.2): what the journey came to once the server
/// has counted it, a line and a mark for each thing, and Done to go back to the
/// idle face. It comes when the journey is over, so there is time to read it.
struct JourneyEndCard: View {
    let end: WatchJourneyEnd
    let token: Int
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(LoreCopy.journey(end.activity.flatMap(Activity.init(rawValue:))).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(WatchTheme.sageLight)
                Text(LoreCopy.journeysEnd)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(WatchTheme.cream)
                ForEach(Self.lines(for: end)) { line in
                    HStack(spacing: 8) {
                        MarkView(line.mark, palette: .watch)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(line.text)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                            if let detail = line.detail {
                                Text(detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(WatchTheme.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Button(action: done) {
                    Text(LoreCopy.done)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background(WatchTheme.sage, in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 6)
                .accessibilityIdentifier("watch.journeyEnd.done")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        }
        .task(id: token) { TurnHaptics.journeyEnded() }
    }

    struct Line: Identifiable {
        let id: Int
        let mark: Mark
        let text: String
        var detail: String?
    }

    /// At most this many finds are listed; the rest are on the phone.
    static let findsShown = 6

    /// The level first, then what was taken from the world, the purse and XP,
    /// then what was found. Nothing to say still says where it went.
    static func lines(for end: WatchJourneyEnd) -> [Line] {
        var lines: [(Mark, String, String?)] = []
        if let level = end.levelReached {
            lines.append((.icon(.levelUp, spot: .gold), "Level up!", "Level \(level)"))
        }
        if end.creaturesDefeated > 0 {
            lines.append((.token(.sword), "\(end.creaturesDefeated) \(end.creaturesDefeated == 1 ? "creature" : "creatures") defeated", nil))
        }
        if end.chestsOpened > 0 {
            lines.append((.chest(tier: 1), "\(end.chestsOpened) \(end.chestsOpened == 1 ? "chest" : "chests") opened", nil))
        }
        if end.coins > 0 {
            lines.append((.coin, LoreCopy.earned(end.coins), nil))
        }
        if end.xp > 0 {
            lines.append((.icon(.star, spot: .gold), "+\(end.xp.formatted()) XP", nil))
        }
        for find in end.finds.prefix(findsShown) {
            lines.append((WristMarks.find(find), find.name, WristMarks.rarityWord(find.rarity)))
        }
        if end.finds.count > findsShown {
            lines.append((.icon(.sparkles), "\(end.finds.count - findsShown) more on your iPhone", nil))
        }
        if lines.isEmpty {
            lines.append((.icon(.openBook), "Saved to your Journal", nil))
        }
        return lines.enumerated().map { Line(id: $0.offset, mark: $0.element.0, text: $0.element.1, detail: $0.element.2) }
    }
}
