import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The Look (0.9.0), from Character: the route ink the World and the Journal draw
/// your journeys in, the frame round your marker on the map, and the frame round
/// your crest. More come from the stall; crest frames from deeds too.
struct LookScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var wearing: String?
    @State private var error: String?

    private var inventory: InventoryState? { container.session.inventory }
    private var look: Look { inventory?.look ?? .plain }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                preview
                if let error { ErrorLine(text: error) }
                if inventory != nil, inventory?.look == nil, inventory?.cosmetics == nil {
                    EmptyState(icon: .inkSwirl, title: "Looks aren't here yet", message: "They arrive with the next server update.")
                        .accessibilityIdentifier("look.missing")
                } else {
                    inkSection
                    markerSection
                    crestSection
                    Text("More inks and frames come to the stall. Crest frames also come from your deeds.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("Look")
        .navigationBarTitleDisplayMode(.inline)
        .task { await container.session.refreshInventory() }
        .refreshable { await container.session.refreshInventory() }
    }

    // MARK: Preview

    private var preview: some View {
        HStack(spacing: 18) {
            FramedCrest(characterClass: container.session.character?.characterClass ?? .explorer, size: 72, frameId: look.crestFrame)
                .accessibilityIdentifier("look.crest")
            VStack(alignment: .leading, spacing: 10) {
                RouteSample(color: Color(hex: LookStyle.inkHex(inventory)))
                    .frame(height: 34)
                    .accessibilityIdentifier("look.inkSample")
                HStack(spacing: 8) {
                    MarkerFrameSample(frame: LookStyle.MarkerFrame(look.markerFrame), size: 34)
                    Text("Your marker on the map").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("look.preview")
    }

    // MARK: Choices

    /// The owned looks of a kind, with the plain one first when the server did not list it.
    private func choices(_ kind: CosmeticKind) -> [Cosmetic] {
        var owned = inventory?.cosmetics(kind) ?? []
        let plain = Cosmetic(itemId: "\(kind.prefix):\(Self.plainId(kind))", kind: kind.rawValue,
                             name: kind == .ink ? "Ink" : "Plain", color: kind == .ink ? "#2E2A24" : nil)
        if !owned.contains(where: { CosmeticKind.bareId($0.itemId) == Self.plainId(kind) }) {
            owned.insert(plain, at: 0)
        }
        return owned
    }

    /// The look everyone has, worn until another is chosen.
    private static func plainId(_ kind: CosmeticKind) -> String {
        switch kind {
        case .ink: return CosmeticCatalog.plainInk
        case .markerFrame: return CosmeticCatalog.plainMarkerFrame
        case .crestFrame: return CosmeticCatalog.plainCrestFrame
        }
    }

    private func isWorn(_ cosmetic: Cosmetic, _ kind: CosmeticKind) -> Bool {
        if look.wears(cosmetic.itemId, as: kind) { return true }
        // Nothing worn is the plain one.
        return look.value(kind) == nil && CosmeticKind.bareId(cosmetic.itemId) == Self.plainId(kind)
    }

    private var inkSection: some View {
        section(.ink, hint: "Your route and your journeys on the map.") { cosmetic, worn in
            Circle().fill(LookStyle.swatch(cosmetic))
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(worn ? Theme.Colors.ink : Theme.Colors.ink.opacity(0.2), lineWidth: worn ? 3 : 1).padding(-4))
        }
    }

    private var markerSection: some View {
        section(.markerFrame, hint: "Round your marker on the World map and on the ride.") { cosmetic, worn in
            MarkerFrameSample(frame: LookStyle.MarkerFrame(cosmetic.itemId), size: 40)
                .overlay(Circle().stroke(worn ? Theme.Colors.ink : .clear, lineWidth: 2.5).padding(-3))
        }
    }

    private var crestSection: some View {
        section(.crestFrame, hint: "Round your crest on your character. Each deed tier you reach gives one.") { cosmetic, worn in
            FramedCrest(characterClass: container.session.character?.characterClass ?? .explorer, size: 34, frameId: cosmetic.itemId)
                .overlay(Circle().stroke(worn ? Theme.Colors.ink : .clear, lineWidth: 2.5).padding(-3))
        }
    }

    private func section(_ kind: CosmeticKind, hint: String, @ViewBuilder sample: @escaping (Cosmetic, Bool) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: kind.name)
            Text(hint).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 10)], spacing: 10) {
                ForEach(choices(kind)) { cosmetic in
                    let worn = isWorn(cosmetic, kind)
                    Button { Task { await wear(cosmetic, kind) } } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                sample(cosmetic, worn)
                                if wearing == cosmetic.itemId { ProgressView().tint(Theme.Colors.ink) }
                            }
                            .frame(height: 46)
                            Text(cosmetic.name).font(Theme.Typography.text(12, worn ? .bold : .regular)).foregroundStyle(Theme.Colors.ink)
                                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(worn ? Theme.Colors.sageTint : Theme.Colors.surface,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    }
                    .buttonStyle(.pressable)
                    .disabled(wearing != nil || worn)
                    .accessibilityLabel("\(cosmetic.name)\(worn ? ", worn" : "")")
                    .accessibilityIdentifier("look.\(kind.prefix).\(CosmeticKind.bareId(cosmetic.itemId))")
                }
            }
        }
    }

    private func wear(_ cosmetic: Cosmetic, _ kind: CosmeticKind) async {
        wearing = cosmetic.itemId
        defer { wearing = nil }
        do {
            container.session.take(inventory: try await container.api.setLook(LookChoice(kind, cosmetic.itemId)))
            error = nil
            UISelectionFeedbackGenerator().selectionChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A short curve of route in an ink, for the Look screen.
struct RouteSample: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 4, y: size.height * 0.7))
            path.addCurve(to: CGPoint(x: size.width - 4, y: size.height * 0.35),
                          control1: CGPoint(x: size.width * 0.35, y: -size.height * 0.2),
                          control2: CGPoint(x: size.width * 0.6, y: size.height * 1.3))
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}
