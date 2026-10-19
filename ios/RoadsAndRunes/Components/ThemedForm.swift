import SwiftUI

// MARK: - Forms in the theme

/// A stock `Form` (or grouped `List`) dressed like the rest of the app: cream ground,
/// Figtree rows, controls in terracotta deep (the colour that still reads on surface),
/// and room at the bottom so the floating tab bar never covers the last row.
/// Pair it with `FormSection`, which gives the rows their surface cards and the
/// sections their Caprasimo titles.
struct ThemedFormStyle: ViewModifier {
    /// Pushed screens sit above the floating tab bar; sheets don't, and need no clearance.
    var clearsTabBar = true

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.Colors.cream)
            .font(Theme.Typography.body)
            .tint(Theme.Colors.terracottaDeep)
            .contentMargins(.bottom, clearsTabBar ? Theme.Layout.tabBarClearance : 0, for: .scrollContent)
    }
}

extension View {
    func themedForm(clearsTabBar: Bool = true) -> some View {
        modifier(ThemedFormStyle(clearsTabBar: clearsTabBar))
    }

    /// A destructive action in a themed form. The app has no red: it is ember, a step
    /// heavier than the actions beside it, and its role still tells VoiceOver.
    func themedDestructive() -> some View {
        font(Theme.Typography.bodyStrong).foregroundStyle(Theme.Colors.ember)
    }
}

/// A form section on a surface card, under a Caprasimo title like the app's other sections.
struct FormSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
                .listRowBackground(Theme.Colors.surface)
                .listRowSeparatorTint(Theme.Colors.line)
        } header: {
            if let title {
                SectionHeader(title: title).textCase(nil)
            }
        }
    }
}
