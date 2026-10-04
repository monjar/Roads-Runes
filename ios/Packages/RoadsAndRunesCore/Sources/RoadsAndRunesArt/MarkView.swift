import SwiftUI

/// Where an illustration can stand in for a drawn mark later (docs/ROADMAP.md,
/// 1.0). Nothing is registered today, so every mark is drawn.
@MainActor
public enum ArtSlots {
    public static var illustration: (Mark) -> Image? = { _ in nil }
}

/// A mark drawn at whatever size it is given, square.
///
/// A mark beside its own name passes no label and is hidden from VoiceOver; a
/// mark standing alone passes its name ("Raido, the road-rune").
public struct MarkView: View {
    let mark: Mark
    let palette: InkPalette
    let label: String?

    public init(_ mark: Mark, palette: InkPalette = .phone, label: String? = nil) {
        self.mark = mark
        self.palette = palette
        self.label = label
    }

    public var body: some View {
        Group {
            if let image = ArtSlots.illustration(mark) {
                image.resizable().scaledToFit()
            } else {
                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    context.withCGContext { cg in
                        MarkRenderer.draw(mark, in: cg, rect: rect, palette: palette)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }
}

/// How much hold a thing has left, as ten ticks round a ring. It redraws in
/// whole tenths with no animation and no numbers, so it can sit on the ride
/// screen without asking to be read (docs/ROADMAP.md, 0.6.1).
public struct HoldRing: View {
    let fraction: Double
    let palette: InkPalette
    let lineWidth: CGFloat

    public init(fraction: Double, palette: InkPalette = .phone, lineWidth: CGFloat = 3) {
        self.fraction = fraction
        self.palette = palette
        self.lineWidth = lineWidth
    }

    /// Whole tenths left, rounded up: a thing at 2% still shows one tick.
    public static func tenths(_ fraction: Double) -> Int {
        let clamped = min(1, max(0, fraction))
        return clamped == 0 ? 0 : Int((clamped * 10).rounded(.up))
    }

    public var body: some View {
        let left = Self.tenths(fraction)
        Canvas { context, size in
            let r = min(size.width, size.height) / 2 - lineWidth
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0 ..< 10 {
                let start = Angle.degrees(-90 + Double(i) * 36 + 3)
                let end = Angle.degrees(-90 + Double(i + 1) * 36 - 3)
                var arc = Path()
                arc.addArc(center: centre, radius: r, startAngle: start, endAngle: end, clockwise: false)
                let color = i < left ? palette.ink : palette.hatch.opacity(0.45)
                context.stroke(arc, with: .color(Color(cgColor: color.cgColor)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .transaction { $0.animation = nil }
        .accessibilityElement()
        .accessibilityLabel("Hold")
        .accessibilityValue("\(left * 10) percent")
    }
}

/// An icon as a SwiftUI shape, for where a system symbol would take a
/// `foregroundStyle`: the tab bar, a row's leading glyph, a button.
///
///     IconShape(.scroll).foregroundStyle(.secondary).frame(width: 20, height: 20)
public struct IconShape: Shape {
    let icon: GameIcon

    public init(_ icon: GameIcon) {
        self.icon = icon
    }

    public func path(in rect: CGRect) -> Path {
        guard let ink = PathCache.shared.path(icon.path) else { return Path() }
        let side = min(rect.width, rect.height)
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return Path(ink.cgPath(grid: CGSize(width: GameIcon.grid, height: GameIcon.grid), in: square))
    }
}
