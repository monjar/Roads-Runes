import SwiftUI

/// Design tokens. Adventure/parchment palette for the world; a high-contrast
/// palette for navigation while moving (spec §33).
enum Theme {
    enum Colors {
        static let ink = Color(red: 0.11, green: 0.10, blue: 0.09)
        static let parchment = Color(red: 0.97, green: 0.94, blue: 0.88)
        static let parchmentDeep = Color(red: 0.92, green: 0.87, blue: 0.78)
        static let moss = Color(red: 0.24, green: 0.44, blue: 0.30)
        static let rune = Color(red: 0.80, green: 0.55, blue: 0.19)
        static let river = Color(red: 0.22, green: 0.47, blue: 0.62)
        static let ember = Color(red: 0.76, green: 0.29, blue: 0.20)
        static let fog = Color.black.opacity(0.55)
        static let fogDiscovered = Color.black.opacity(0.30)
        static let exploredBorder = Color(red: 0.24, green: 0.44, blue: 0.30).opacity(0.5)

        static let background = Color(uiColor: .systemBackground)
        static let surface = Color(uiColor: .secondarySystemBackground)
        static let textPrimary = Color(uiColor: .label)
        static let textSecondary = Color(uiColor: .secondaryLabel)

        // Navigation (high contrast, readable on a handlebar mount).
        static let navBackground = Color.black
        static let navForeground = Color.white
        static let navAccent = Color(red: 1.0, green: 0.78, blue: 0.20)
        static let navWarning = Color(red: 1.0, green: 0.42, blue: 0.30)

        static func difficulty(_ difficulty: String) -> Color {
            switch difficulty {
            case "EASY": return moss
            case "MODERATE": return river
            case "HARD": return rune
            case "EPIC": return ember
            default: return textSecondary
            }
        }
    }

    enum Typography {
        static let display = Font.system(.largeTitle, design: .serif).weight(.bold)
        static let title = Font.system(.title2, design: .serif).weight(.semibold)
        static let heading = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body)
        static let caption = Font.system(.caption)
        static let metric = Font.system(.title, design: .rounded).weight(.semibold).monospacedDigit()
        static let navDistance = Font.system(size: 72, weight: .bold, design: .rounded).monospacedDigit()
        static let navStreet = Font.system(size: 28, weight: .semibold, design: .rounded)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 16
        static let chip: CGFloat = 10
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.md)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}
