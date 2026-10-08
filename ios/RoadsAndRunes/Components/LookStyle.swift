import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI
import UIKit

/// The look worn (0.9.0) as the app draws it: the route ink on the World and
/// Journal maps, the rider marker's frame, the crest's frame. Anything the app
/// does not know yet draws as the plain one.
enum LookStyle {
    /// The route colour with no look at all (a server before 0.9.0): terracotta, as it always was.
    static let plainInk: UInt32 = 0xC67139

    /// The ink's colour, from what is worn and what is owned (an owned ink may carry its colour).
    static func inkHex(_ look: Look?, owned: [Cosmetic]? = nil) -> UInt32 {
        guard let ink = look?.ink else { return plainInk }
        let color = owned?.first { CosmeticKind.bareId($0.itemId) == CosmeticKind.bareId(ink) }?.color
        return CosmeticCatalog.inkHex(ink, color: color) ?? plainInk
    }

    static func inkHex(_ inventory: InventoryState?) -> UInt32 { inkHex(inventory?.look, owned: inventory?.cosmetics) }

    /// The route line's colour for a map, from the bag.
    static func routeColor(_ inventory: InventoryState?) -> UIColor { UIColor(hex: inkHex(inventory)) }

    /// An ink's swatch colour.
    static func swatch(_ cosmetic: Cosmetic) -> Color { Color(hex: CosmeticCatalog.inkHex(cosmetic.itemId, color: cosmetic.color) ?? plainInk) }

    // MARK: Marker frames

    enum MarkerFrame: String, CaseIterable {
        case plain, rope, laurel, runic

        init(_ id: String?) {
            let bare = id.map { CosmeticKind.bareId($0).lowercased() } ?? "plain"
            self = MarkerFrame(rawValue: bare) ?? .plain
        }
    }

    // MARK: Crest frames

    /// A crest frame: a deed's ("legs-3": its colour, ticks for its tier) or a bought one.
    struct CrestFrame: Equatable {
        var color: Color
        var ticks: Int
        var double: Bool

        init?(_ id: String?) {
            guard let id else { return nil }
            let bare = CosmeticKind.bareId(id).lowercased()
            let parts = bare.split(separator: "-")
            if parts.count == 2, let tier = Int(parts[1]), let deed = Self.deedColors[String(parts[0])] {
                self.color = deed
                self.ticks = max(1, min(5, tier))
                self.double = tier >= 5
                return
            }
            // The three from the stall (`inventory/config/cosmetics.json`), then any the app does not know yet.
            switch bare {
            case "plain", "none": return nil
            case "oak": (color, ticks, double) = (Theme.Colors.sageDeep, 12, false)
            case "silver": (color, ticks, double) = (Theme.Colors.mutedLight, 0, true)
            case "starry": (color, ticks, double) = (Theme.Colors.gold, 8, false)
            default: (color, ticks, double) = (Theme.Colors.terracottaDeep, 0, true)
            }
        }

        /// The five deeds' colours.
        static let deedColors: [String: Color] = [
            "legs": Theme.Colors.terracottaDeep, "lungs": Theme.Colors.sageDeep, "eyes": Theme.Colors.gold,
            "hand": Theme.Colors.wizard, "ink": Theme.Colors.ink,
        ]
    }
}

/// A class's crest in the frame worn (0.9.0); with none, the crest alone.
struct FramedCrest: View {
    let characterClass: CharacterClass
    var size: CGFloat = 32
    var frameId: String?

    var body: some View {
        let frame = LookStyle.CrestFrame(frameId)
        let outer = frame == nil ? size : size * 1.18
        ZStack {
            if let frame {
                CrestFrameShape(frame: frame).frame(width: outer, height: outer)
            }
            ClassEmblem(characterClass: characterClass, size: size)
        }
        .frame(width: outer, height: outer)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClassStyle.name(characterClass))
    }
}

/// The ring a crest frame draws behind the crest: a band, its tier's ticks, a second ring at the top tier.
struct CrestFrameShape: View {
    let frame: LookStyle.CrestFrame

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let band = max(2, radius * 0.09)
            let outer = CGRect(x: centre.x - radius + band / 2, y: centre.y - radius + band / 2, width: (radius - band / 2) * 2, height: (radius - band / 2) * 2)
            context.fill(Path(ellipseIn: outer), with: .color(Theme.Colors.cream))
            context.stroke(Path(ellipseIn: outer), with: .color(frame.color), lineWidth: band)
            if frame.double {
                let inner = outer.insetBy(dx: band * 1.8, dy: band * 1.8)
                context.stroke(Path(ellipseIn: inner), with: .color(frame.color.opacity(0.7)), lineWidth: band * 0.45)
            }
            guard frame.ticks > 0 else { return }
            for index in 0..<frame.ticks {
                let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(frame.ticks, 1))
                let point = CGPoint(x: centre.x + cos(angle) * (radius - band / 2), y: centre.y + sin(angle) * (radius - band / 2))
                let dot = CGRect(x: point.x - band * 0.85, y: point.y - band * 0.85, width: band * 1.7, height: band * 1.7)
                context.fill(Path(ellipseIn: dot), with: .color(Theme.Colors.cream))
                context.stroke(Path(ellipseIn: dot), with: .color(frame.color), lineWidth: band * 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A marker frame as a small picture, for the Look screen.
struct MarkerFrameSample: View {
    let frame: LookStyle.MarkerFrame
    var size: CGFloat = 44

    var body: some View {
        Canvas { context, canvas in
            let centre = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let dot = canvas.width * 0.42
            let ring = CGRect(x: centre.x - dot / 2 - 4, y: centre.y - dot / 2 - 4, width: dot + 8, height: dot + 8)
            context.fill(Path(ellipseIn: ring), with: .color(Theme.Colors.cream))
            for layer in RiderFrameDrawing.strokes(frame, ring: ring) {
                context.stroke(layer.path, with: .color(Color(uiColor: layer.color)), style: layer.style)
            }
            context.fill(Path(ellipseIn: CGRect(x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot)), with: .color(Theme.Colors.terracotta))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The strokes of a marker frame round a ring, shared by the map's rider marker and its sample.
enum RiderFrameDrawing {
    struct Stroke {
        var path: Path
        var color: UIColor
        var style: StrokeStyle
    }

    static func strokes(_ frame: LookStyle.MarkerFrame, ring: CGRect) -> [Stroke] {
        let centre = CGPoint(x: ring.midX, y: ring.midY)
        let radius = ring.width / 2
        switch frame {
        case .plain:
            return [Stroke(path: Path(ellipseIn: ring), color: UIColor(hex: 0xF5EAD8), style: StrokeStyle(lineWidth: 4))]
        case .rope:
            return [
                Stroke(path: Path(ellipseIn: ring), color: UIColor(hex: 0x8C491A), style: StrokeStyle(lineWidth: 4)),
                Stroke(path: Path(ellipseIn: ring), color: UIColor(hex: 0xE6C9A0), style: StrokeStyle(lineWidth: 2.5, dash: [3, 3])),
            ]
        case .laurel:
            var leaves = Path()
            for index in 0..<10 {
                let angle = Double(index) * 2 * .pi / 10
                let base = CGPoint(x: centre.x + cos(angle) * radius, y: centre.y + sin(angle) * radius)
                let tip = CGPoint(x: centre.x + cos(angle + 0.35) * (radius + 5), y: centre.y + sin(angle + 0.35) * (radius + 5))
                leaves.move(to: base)
                leaves.addLine(to: tip)
            }
            return [
                Stroke(path: Path(ellipseIn: ring), color: UIColor(hex: 0x56633F), style: StrokeStyle(lineWidth: 3)),
                Stroke(path: leaves, color: UIColor(hex: 0x56633F), style: StrokeStyle(lineWidth: 2.5, lineCap: .round)),
            ]
        case .runic:
            var notches = Path()
            for index in 0..<8 {
                let angle = Double(index) * 2 * .pi / 8 + .pi / 8
                let inner = CGPoint(x: centre.x + cos(angle) * (radius - 2), y: centre.y + sin(angle) * (radius - 2))
                let outer = CGPoint(x: centre.x + cos(angle) * (radius + 4), y: centre.y + sin(angle) * (radius + 4))
                notches.move(to: inner)
                notches.addLine(to: outer)
            }
            return [
                Stroke(path: Path(ellipseIn: ring), color: UIColor(hex: 0x201E1D), style: StrokeStyle(lineWidth: 3)),
                Stroke(path: notches, color: UIColor(hex: 0x201E1D), style: StrokeStyle(lineWidth: 2, lineCap: .round)),
            ]
        }
    }
}
