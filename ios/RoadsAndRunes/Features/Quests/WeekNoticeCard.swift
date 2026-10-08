import RoadsAndRunesCore
import SwiftUI

/// The week's notice on the Quests tab (docs/ROADMAP.md, 0.6.2): one goal a week,
/// pinned by Ada Pym, with how far along it is and what it pays.
struct WeekNoticeCard: View {
    let notice: WeekNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "This week", color: Theme.Colors.sageDeep)
                Spacer()
                Text(standing).font(Theme.Typography.captionStrong.monospacedDigit())
                    .foregroundStyle(notice.done ? Theme.Colors.sageDeep : Theme.Colors.muted)
            }
            Text(notice.title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
            ProgressView(value: notice.fraction).tint(Theme.Colors.sageDeep)
                .accessibilityValue("\(notice.progress) of \(notice.target)")
            if let line = notice.line {
                (Text("\u{201C}\(line)\u{201D} ").italic().foregroundStyle(Theme.Colors.inkSoft)
                    + Text(notice.postedBy ?? "Ada Pym").font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.muted))
                    .font(Theme.Typography.caption)
            }
        }
        .padding(16)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("weekNotice")
    }

    private var standing: String {
        if notice.paid { return "Done · reward paid" }
        var parts = ["\(notice.progress) of \(notice.target)"]
        if let coins = notice.coins { parts.append(LoreCopy.purse(coins)) }
        return parts.joined(separator: " · ")
    }
}
