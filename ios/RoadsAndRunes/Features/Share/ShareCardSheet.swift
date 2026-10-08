import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// "Share card" from Journey's end and the Journal (0.7.3): the card as it will
/// look, "Add my route" (off unless switched on, and refused under 2.5 km), and
/// the share sheet with the picture.
struct ShareCardSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let summary: AdventureSummary
    @State private var addRoute = false
    @State private var trace: [Coordinate]?
    @State private var loadingTrace = false
    @State private var image: UIImage?

    private var units: Units { container.session.units }

    /// The masked trace, when there is one long enough to add.
    private var masked: [Coordinate]? { trace.flatMap { TraceMask.shareable($0) } }

    private var tooShort: Bool { trace != nil && masked == nil }

    private var content: ShareCardContent {
        ShareCardContent.make(summary: summary, character: container.session.character, units: units, trace: addRoute ? masked : nil)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Eyebrow(text: "Share card", color: Theme.Colors.terracottaDeep)
                    Spacer()
                    IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34) { dismiss() }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("share.close")
                }
                ShareCardView(content: content)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 6)
                    .frame(maxWidth: .infinity)
                Toggle(isOn: $addRoute) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add my route").font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink)
                        Text(tooShort ? TraceMask.tooShortLine : "The first and last kilometre are left off, so where you start and end stays yours.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(tooShort ? Theme.Colors.terracottaDeep : Theme.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("share.routeNote")
                    }
                }
                .tint(Theme.Colors.sage)
                .disabled(loadingTrace || tooShort)
                .accessibilityIdentifier("share.addRoute")
                Text("The card shows no map and no place names.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Share card", image: Image(uiImage: image))) {
                        Label("Share card", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("share.send")
                } else {
                    ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                }
            }
            .padding(22)
        }
        .background(Theme.Colors.cream.ignoresSafeArea())
        .task {
            loadingTrace = true
            trace = (try? await container.api.rideGeometry(id: summary.ride.id))?.path ?? []
            loadingTrace = false
            render()
        }
        .onChange(of: addRoute) { _, _ in render() }
    }

    private func render() {
        image = ShareCardView.render(content)
    }
}
