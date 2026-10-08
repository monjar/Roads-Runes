import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The app's paper and ink, for the widgets and the Live Activity
/// (`RoadsAndRunes/Components/Theme.swift` is the app's own and is not shared).
enum WidgetStyle {
    static let cream = Color(hex: 0xF5EAD8)
    static let surface = Color(hex: 0xEBDDC5)
    static let track = Color(hex: 0xDCD3C4)
    static let ink = Color(hex: 0x201E1D)
    static let muted = Color(hex: 0x645C50)
    static let terracotta = Color(hex: 0xC67139)
    static let terracottaLight = Color(hex: 0xF6A06B)
    static let sage = Color(hex: 0x7A8A5E)
    static let gold = Color(hex: 0xD9A621)
    static let creamOnBlack = Color(hex: 0xF5EAD8)
    static let mutedOnBlack = Color(hex: 0xC0B6A5)

    /// Caprasimo for names and the big number, Figtree for everything else; both
    /// are bundled with the extension (`UIAppFonts`).
    static func voice(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("Caprasimo-Regular", size: size, relativeTo: style)
    }

    static func text(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(bold ? "Figtree-Bold" : "Figtree-SemiBold", size: size, relativeTo: style)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Mark {
    /// A creature's mark from the `GameIcon` name the app wrote down.
    static func creature(icon: String?, bounty: Bool) -> Mark {
        .creature(Sigil(body: "", feature: "", mark: "", icon: icon), bounty: bounty)
    }
}

/// The quarry's mark inside its ring of health: ten ticks, no numbers, no words.
struct QuarryRing: View {
    let icon: String?
    let tenthsLeft: Int
    var palette: InkPalette = .phone
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            HoldRing(fraction: Double(tenthsLeft) / 10, palette: palette, lineWidth: lineWidth)
            MarkView(.creature(icon: icon, bounty: false), palette: palette)
                .padding(lineWidth * 2.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health \(tenthsLeft * 10) percent")
    }
}
