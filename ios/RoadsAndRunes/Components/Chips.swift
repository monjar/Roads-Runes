import SwiftUI

struct DifficultyChip: View {
    let difficulty: String

    var body: some View {
        Text(difficulty.capitalized)
            .font(Theme.Typography.caption.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Colors.difficulty(difficulty).opacity(0.18), in: Capsule())
            .foregroundStyle(Theme.Colors.difficulty(difficulty))
    }
}

struct StatChip: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.Typography.title)
            if let subtitle { Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary) }
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
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.Colors.rune)
            Text(title).font(Theme.Typography.heading)
            Text(message).font(Theme.Typography.body).foregroundStyle(Theme.Colors.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
    }
}
