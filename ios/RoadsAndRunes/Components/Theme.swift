import RoadsAndRunesCore
import SwiftUI

/// Design tokens from the Claude Design "Cycling Companion" system
/// (`docs/design/Cycling Companion.dc.html`, turns 0 and 2).
///
/// Cream ground, surface cards and pills. Terracotta is reserved for *the*
/// route and the primary action; sage is the calm second voice ("you",
/// success, the Explorer). Class colour touches emblems, quest markers and XP
/// bars only. Caprasimo is the companion voice (screen titles, quest and
/// route names, primary buttons); Figtree carries body copy and every number
/// a rider reads while moving.
enum Theme {
    enum Colors {
        // Ground and surfaces
        static let cream = Color(hex: 0xF5EAD8)
        static let surface = Color(hex: 0xEBDDC5)
        static let track = Color(hex: 0xDCD3C4)
        static let line = Color(hex: 0xC0B6A5)
        static let hatch = Color(hex: 0xA19786)

        // Ink
        static let ink = Color(hex: 0x201E1D)
        static let inkSoft = Color(hex: 0x474238)
        static let muted = Color(hex: 0x645C50)
        static let mutedLight = Color(hex: 0x82796A)

        // Terracotta: the route, the primary action, the Warrior
        static let terracotta = Color(hex: 0xC67139)
        static let terracottaDeep = Color(hex: 0x8C491A)
        static let terracottaLight = Color(hex: 0xF6A06B)
        static let terracottaTint = Color(hex: 0xFFE1D0)
        static let terracottaText = Color(hex: 0x643312)

        // Sage: you, success, the Explorer
        static let sage = Color(hex: 0x7A8A5E)
        static let sageDeep = Color(hex: 0x56633F)
        static let sageLight = Color(hex: 0xAEBF92)
        static let sageTint = Color(hex: 0xE1EECC)
        static let sageText = Color(hex: 0x3D472B)
        static let compactGravel = Color(hex: 0x728157)

        // Other class hues (derived in OKLCH at the accents' chroma)
        static let wizard = Color(hex: 0x6B5F8F)
        static let wizardLight = Color(hex: 0xB9AFD9)
        static let scribe = Color(hex: 0x4F6B7A)
        static let scribeLight = Color(hex: 0xA3BCC9)
        static let heartRate = Color(hex: 0xFF8F8F)

        // Semantic aliases
        static let parchment = cream
        static let parchmentDeep = surface
        static let moss = sage
        static let rune = terracotta
        static let river = scribe
        static let ember = terracottaDeep
        static let background = cream
        static let textPrimary = ink
        static let textSecondary = muted

        // Fog of war on the ink map: unexplored ground is cream, roads ghost through.
        static let fog = cream.opacity(0.93)
        static let fogDiscovered = cream.opacity(0.6)
        static let exploredBorder = muted

        // Navigation: ink pills on the cream map, terracotta-light for warnings.
        static let navBackground = ink
        static let navForeground = cream
        static let navAccent = terracottaLight
        static let navWarning = terracottaLight

        static func difficulty(_ difficulty: String) -> Color {
            switch difficulty {
            case "EASY": return sageText
            case "MODERATE": return terracottaText
            case "HARD": return terracottaDeep
            case "EPIC": return cream
            default: return muted
            }
        }

        static func difficultyTint(_ difficulty: String) -> Color {
            switch difficulty {
            case "EASY": return sageTint
            case "MODERATE": return terracottaTint
            case "HARD": return Color(hex: 0xF3C7A8)
            case "EPIC": return ink
            default: return surface
            }
        }
    }

    enum Fonts {
        static let caprasimo = "Caprasimo-Regular"
        static let figtree = "Figtree-Regular"
        static let figtreeSemibold = "Figtree-SemiBold"
        static let figtreeBold = "Figtree-Bold"
    }

    enum Typography {
        enum Weight { case regular, semibold, bold }

        /// The companion voice: Caprasimo, for titles, quest and route names, primary buttons.
        static func voice(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
            .custom(Fonts.caprasimo, size: size, relativeTo: style)
        }

        /// Figtree for everything else; 700 for every number a rider reads while moving.
        static func text(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
            let name: String
            switch weight {
            case .regular: name = Fonts.figtree
            case .semibold: name = Fonts.figtreeSemibold
            case .bold: name = Fonts.figtreeBold
            }
            return .custom(name, size: size, relativeTo: style)
        }

        static let display = voice(34, relativeTo: .largeTitle)
        static let title = voice(26, relativeTo: .title)
        static let heading = voice(20, relativeTo: .title2)
        static let cardTitle = voice(17, relativeTo: .title3)
        static let button = voice(19, relativeTo: .title3)
        static let buttonSmall = voice(16, relativeTo: .headline)

        static let body = text(15)
        static let bodyStrong = text(15, .semibold)
        static let label = text(14, .bold, relativeTo: .subheadline)
        static let caption = text(12.5, relativeTo: .caption)
        static let captionStrong = text(12, .semibold, relativeTo: .caption)
        static let eyebrow = text(11, .bold, relativeTo: .caption2)
        static let tab = text(11, .semibold, relativeTo: .caption2)

        static let number = text(22, .bold, relativeTo: .title2)
        static let numberLarge = text(30, .bold, relativeTo: .title)
        static let numberHero = text(56, .bold, relativeTo: .largeTitle)
        static let xpHero = text(64, .bold, relativeTo: .largeTitle)

        static let metric = number
        static let navDistance = numberHero
        static let navStreet = text(15, relativeTo: .body)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 24
        static let row: CGFloat = 22
        static let tile: CGFloat = 20
        static let sheet: CGFloat = 32
        static let chip: CGFloat = 999
    }

    enum Layout {
        static let tabBarHeight: CGFloat = 62
        /// Bottom padding that keeps scrolling content clear of the floating tab bar.
        static let tabBarClearance: CGFloat = 96
        static let primaryButtonHeight: CGFloat = 60
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Heraldic accents: Explorer · sage · compass star; Wizard · dusk violet · arcane
/// ring; Warrior · terracotta · shield; Scribe · ink blue · drop.
enum ClassStyle {
    static func color(_ characterClass: CharacterClass) -> Color {
        switch characterClass {
        case .wizard: return Theme.Colors.wizard
        case .warrior: return Theme.Colors.terracotta
        case .scribe: return Theme.Colors.scribe
        default: return Theme.Colors.sage
        }
    }

    /// Readable on cream: the darker cousin of the class hue.
    static func textColor(_ characterClass: CharacterClass) -> Color {
        switch characterClass {
        case .wizard: return Theme.Colors.wizard
        case .warrior: return Theme.Colors.terracottaDeep
        case .scribe: return Theme.Colors.scribe
        default: return Theme.Colors.sageDeep
        }
    }

    /// Readable on ink: the lighter cousin of the class hue.
    static func lightColor(_ characterClass: CharacterClass) -> Color {
        switch characterClass {
        case .wizard: return Theme.Colors.wizardLight
        case .warrior: return Theme.Colors.terracottaLight
        case .scribe: return Theme.Colors.scribeLight
        default: return Theme.Colors.sageLight
        }
    }

    static func symbol(_ characterClass: CharacterClass) -> String {
        switch characterClass {
        case .wizard: return "circle.circle"
        case .warrior: return "shield.fill"
        case .scribe: return "drop.fill"
        default: return "sparkle"
        }
    }

    static func name(_ characterClass: CharacterClass) -> String {
        switch characterClass {
        case .unknown: return "Adventurer"
        case .any: return "Open"  // "Open quest": one anyone can take
        default: return characterClass.rawValue.capitalized
        }
    }
}

// MARK: - Styles

struct CardStyle: ViewModifier {
    var background: Color = Theme.Colors.surface
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(background, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func card(_ background: Color = Theme.Colors.surface, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(CardStyle(background: background, radius: radius))
    }

    /// The cream sheet that rises over a map: top corners rounded, soft shadow upwards.
    func sheetSurface() -> some View {
        background(Theme.Colors.cream, in: UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.sheet, topTrailingRadius: Theme.Radius.sheet, style: .continuous))
            .shadow(color: Theme.Colors.ink.opacity(0.16), radius: 12, y: -8)
    }
}

/// Terracotta pill, Caprasimo label: the one primary action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button)
            .foregroundStyle(Theme.Colors.cream)
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Layout.primaryButtonHeight)
            .background(Theme.Colors.terracotta, in: Capsule())
            .contentShape(Capsule())
            .shadow(color: Theme.Colors.ink.opacity(0.22), radius: 16, y: 12)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .dimmedWhenDisabled()
    }
}

/// Surface pill, Figtree 600: the quiet second action beside a primary one.
struct SecondaryButtonStyle: ButtonStyle {
    var expands = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.text(14, .semibold))
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, 18)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(height: Theme.Layout.primaryButtonHeight)
            .background(Theme.Colors.surface, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .dimmedWhenDisabled()
    }
}

/// Small ink pill with cream text (map chips, filters, "All").
struct InkPillButtonStyle: ButtonStyle {
    var selected = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.captionStrong)
            .foregroundStyle(selected ? Theme.Colors.cream : Theme.Colors.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? Theme.Colors.ink : Theme.Colors.surface, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .dimmedWhenDisabled()
    }
}

/// Sage pill: success actions (Resume, "Added ✓").
struct SageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.buttonSmall)
            .foregroundStyle(Theme.Colors.cream)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.Colors.sage, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .dimmedWhenDisabled()
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var secondaryWide: SecondaryButtonStyle { SecondaryButtonStyle(expands: true) }
}

extension ButtonStyle where Self == SageButtonStyle {
    static var sage: SageButtonStyle { SageButtonStyle() }
}

extension ButtonStyle where Self == InkPillButtonStyle {
    static var inkPill: InkPillButtonStyle { InkPillButtonStyle() }
    static var surfacePill: InkPillButtonStyle { InkPillButtonStyle(selected: false) }
}

/// Rows, cards and icons. A plain button only answers taps on its drawn glyphs,
/// so a tap in a row's gap (or beside a label) did nothing; here the whole
/// frame answers, and the press shows.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .dimmedWhenDisabled()
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// A disabled button has to look it, or a tap that does nothing reads as broken.
private struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.4)
    }
}

extension View {
    func dimmedWhenDisabled() -> some View { modifier(DimmedWhenDisabled()) }
}

// MARK: - Small shared views

/// Small caps label above a title: "EXPLORER QUEST · 3.2 KM AWAY".
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.Colors.muted

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Typography.eyebrow)
            .tracking(0.7)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Surface tile with one big number and a small label beneath.
struct FactTile: View {
    let value: String
    let label: String
    var valueColor: Color = Theme.Colors.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(Theme.Typography.number)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }
}

struct SheetHandle: View {
    var body: some View {
        Capsule().fill(Theme.Colors.line).frame(width: 40, height: 5)
    }
}

/// Class emblem in a circle. `inverted` puts the glyph in class colour on cream.
struct ClassEmblem: View {
    let characterClass: CharacterClass
    var size: CGFloat = 32
    var inverted = false

    var body: some View {
        ZStack {
            Circle().fill(inverted ? Theme.Colors.cream : ClassStyle.color(characterClass))
            Image(systemName: ClassStyle.symbol(characterClass))
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(inverted ? ClassStyle.color(characterClass) : Theme.Colors.cream)
        }
        .frame(width: size, height: size)
    }
}

/// Quest waypoints are diamonds: shape carries meaning before colour does.
struct DiamondMarker: View {
    var color: Color = Theme.Colors.sage
    var label: String? = nil
    var size: CGFloat = 22
    var dashed = false
    var done = false

    var body: some View {
        ZStack {
            if dashed {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Theme.Colors.mutedLight, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .rotationEffect(.degrees(45))
                    .frame(width: size * 0.8, height: size * 0.8)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(color)
                    .rotationEffect(.degrees(45))
                    .frame(width: size * 0.8, height: size * 0.8)
                if done {
                    Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .heavy)).foregroundStyle(.white)
                } else if let label {
                    Text(label).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// "Moderate for you": difficulty judged against the rider's cycling profile.
struct SuitabilityChip: View {
    let difficulty: Difficulty
    var forYou = true

    var body: some View {
        let raw = difficulty.rawValue
        Text(forYou ? "\(raw.capitalized) for you" : raw.capitalized)
            .font(Theme.Typography.captionStrong)
            .foregroundStyle(Theme.Colors.difficulty(raw))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.Colors.difficultyTint(raw), in: Capsule())
    }
}

/// Ink pill with an optional status dot: "Watch · navigating", "12.6 km² revealed".
struct StatusPill: View {
    let text: String
    var dot: Color? = nil
    var foreground: Color = Theme.Colors.cream
    var background: Color = Theme.Colors.ink

    var body: some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
            Text(text).font(Theme.Typography.captionStrong).lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(background, in: Capsule())
    }
}

/// Translucent cream pill that sits on a map.
struct MapPill: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .bold)) }
            Text(text).font(Theme.Typography.captionStrong).lineLimit(1)
        }
        .foregroundStyle(Theme.Colors.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.Colors.cream.opacity(0.94), in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 2, y: 1)
    }
}

/// 40pt circular icon button used over maps (back, style, share).
struct IconCircleButton: View {
    let symbol: String
    var background: Color = Theme.Colors.cream.opacity(0.92)
    var foreground: Color = Theme.Colors.ink
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 2, y: 1)
        }
        .buttonStyle(.pressable)
    }
}

/// Progress track. Sage by default; cream on class-coloured headers.
struct ProgressTrack: View {
    let fraction: Double
    var fill: Color = Theme.Colors.sage
    var track: Color = Theme.Colors.track
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

/// Wrapping row of pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth == .infinity ? widest : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Concentric-ring pattern that decorates class-coloured headers and the current-quest card.
struct RingPattern: View {
    var color: Color = Theme.Colors.cream
    var opacity: Double = 0.12
    var step: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width, y: 0)
            var radius = step
            let limit = max(size.width, size.height) * 1.6
            while radius < limit {
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(opacity)), lineWidth: 1)
                radius += step
            }
        }
        .allowsHitTesting(false)
    }
}
