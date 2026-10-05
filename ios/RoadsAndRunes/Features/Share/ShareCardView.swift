import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The picture of a journey to send someone (0.7.3): the creature, the entry's
/// first line, deeds and title, in a frame of the class's colour under its
/// crest. Drawn by `ImageRenderer`, so nothing here may be a live map.
struct ShareCardView: View {
    let content: ShareCardContent

    static let size = CGSize(width: 360, height: 480)

    private var accent: Color { ClassStyle.color(content.characterClass) }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Colors.cream
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(accent, lineWidth: 6)
                .padding(10)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                .padding(20)
            VStack(spacing: 10) {
                // The crest sits on the frame's top edge.
                MarkView(.crest(content.characterClass.rawValue.lowercased()))
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Theme.Colors.cream).padding(-4))
                    .padding(.top, 0)
                VStack(spacing: 2) {
                    Text(content.characterName)
                        .font(Theme.Typography.voice(22, relativeTo: .title2)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                    Text([content.title, content.classLine].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Typography.text(12, .semibold)).foregroundStyle(accent).lineLimit(1)
                }
                if let creature = content.creature {
                    creatureBlock(creature)
                } else if content.trace == nil {
                    MarkView(.rider(content.activity.rawValue))
                        .frame(width: 72, height: 72)
                        .padding(.vertical, 6)
                }
                if let trace = content.trace, trace.count >= 2 {
                    TraceShape(points: trace)
                        .stroke(Theme.Colors.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(height: content.creature == nil ? 150 : 84)
                        .padding(.horizontal, 30)
                        .accessibilityLabel("Your route, without its first and last kilometre")
                }
                if let sentence = content.sentence {
                    Text(sentence)
                        .font(Theme.Typography.text(14)).italic().foregroundStyle(Theme.Colors.inkSoft)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 34)
                }
                if !content.deeds.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(content.deeds, id: \.self) { deed in
                            HStack(spacing: 6) {
                                MarkView(.icon(.trophy, spot: .gold)).frame(width: 16, height: 16)
                                Text(deed).font(Theme.Typography.text(12.5, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Text(content.journeyLine)
                    Spacer()
                    Text(content.date.formatted(date: .abbreviated, time: .omitted))
                }
                .font(Theme.Typography.text(11.5, .semibold)).foregroundStyle(Theme.Colors.muted)
                .padding(.horizontal, 36)
                Text("Roads & Runes")
                    .font(Theme.Typography.voice(13, relativeTo: .caption)).foregroundStyle(accent)
                    .padding(.bottom, 30)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shareCard")
    }

    private func creatureBlock(_ creature: ShareCardContent.Creature) -> some View {
        VStack(spacing: 4) {
            MarkView(creature.mark).frame(width: 84, height: 84)
            Text(creature.name).font(Theme.Typography.voice(20, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
            Text(creature.line).font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.terracottaDeep)
                .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 30)
            if let health = creature.health {
                Text(health).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
    }

    /// The card as a picture, for sharing.
    @MainActor
    static func render(_ content: ShareCardContent, scale: CGFloat = 3) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCardView(content: content))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage
    }
}

/// A trace drawn as a line, fitted into its frame, north up: no map beneath it.
struct TraceShape: Shape {
    let points: [Coordinate]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let ys = points.map(\.latitude)
        guard points.count >= 2, let minY = ys.min(), let maxY = ys.max() else { return path }
        // Longitude shrinks with latitude: scale it so the shape is not stretched.
        let shrink = cos((minY + maxY) / 2 * .pi / 180)
        let xs = points.map { $0.longitude * shrink }
        guard let minX = xs.min(), let maxX = xs.max() else { return path }
        let span = max(maxX - minX, maxY - minY, 1e-9)
        let scale = min(rect.width, rect.height) / span
        let offsetX = rect.minX + (rect.width - (maxX - minX) * scale) / 2
        let offsetY = rect.minY + (rect.height - (maxY - minY) * scale) / 2
        for (index, x) in xs.enumerated() {
            let point = CGPoint(x: offsetX + (x - minX) * scale, y: offsetY + (maxY - ys[index]) * scale)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
