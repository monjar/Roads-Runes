import RoadsAndRunesCore
import SwiftUI

struct DifficultyChip: View {
    let difficulty: String
    var forYou = false

    var body: some View {
        Text(forYou ? "\(difficulty.capitalized) for you" : difficulty.capitalized)
            .font(Theme.Typography.captionStrong)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.Colors.difficultyTint(difficulty), in: Capsule())
            .foregroundStyle(Theme.Colors.difficulty(difficulty))
    }
}

struct StatChip: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.muted)
    }
}

/// Caprasimo section title with an optional quiet trailing note.
struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
            Spacer(minLength: 8)
            if let subtitle {
                Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.Colors.hatch)
            Text(title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
            Text(message).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
    }
}

/// Segmented control as a surface pill with an ink thumb (Journal tabs).
struct SegmentedPill<Option: Hashable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.snappy) { selection = option }
                } label: {
                    Text(title(option))
                        .font(Theme.Typography.text(13, .semibold))
                        .foregroundStyle(selection == option ? Theme.Colors.cream : Theme.Colors.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selection == option ? Theme.Colors.ink : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Theme.Colors.surface, in: Capsule())
    }
}

/// Filter chip: ink when selected, surface otherwise ("All 41", "Natural 14").
struct FilterChip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(text) }
            .buttonStyle(InkPillButtonStyle(selected: selected))
    }
}

/// Inline error line in the design's terracotta-deep link colour.
struct ErrorLine: View {
    let text: String

    var body: some View {
        Text(text).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
    }
}
