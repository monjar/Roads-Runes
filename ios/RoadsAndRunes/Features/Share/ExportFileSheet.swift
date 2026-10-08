import RoadsAndRunesCore
import SwiftUI

/// A route or a journey handed on as a file (docs/GARMIN.md, step 2): what is asked for,
/// and in which shape.
enum ExportRequest: Identifiable, Hashable {
    /// A planned route as a FIT course: "Send to Garmin". Never a sealed quest's route.
    case garminCourse(routeId: UUID)
    /// A journey as a FIT activity to import at connect.garmin.com: "Save for Garmin".
    case garminActivity(rideId: UUID, activity: Activity?)
    /// A journey as GPX, for any other app: "Export GPX".
    case gpx(rideId: UUID, activity: Activity?)

    var id: String {
        switch self {
        case .garminCourse(let id): return "course-\(id.uuidString)"
        case .garminActivity(let id, _): return "activity-\(id.uuidString)"
        case .gpx(let id, _): return "gpx-\(id.uuidString)"
        }
    }

    /// The sheet's words: a title, a line of why, the steps, and the small print.
    var copy: (title: String, intro: String?, steps: [String], note: String?) {
        switch self {
        case .garminCourse:
            return ("Send to Garmin", nil,
                    ["Tap Share file and pick Garmin Connect.", "Save it as a course.", "Sync your Garmin. The route is under Courses."],
                    "Garmin works out its own turns from the line.")
        case .garminActivity(_, let activity):
            return ("Save for Garmin",
                    "Garmin Connect doesn't let other apps add journeys for you, so this one goes in by hand.",
                    ["Share the file to your computer, or save it to Files.", "On connect.garmin.com, choose Import Data and pick the file."],
                    "Skip this if you recorded the \(LoreCopy.journey(activity)) on your Garmin too, or it will be there twice.")
        case .gpx(_, let activity):
            // The file is not masked like the share card: it says so.
            return ("Export GPX", "This \(LoreCopy.journey(activity)) as a GPX file, for any app that opens one.", [],
                    "The file holds your whole route, start and finish included.")
        }
    }
}

/// One small sheet for every export: it fetches the file as it opens (with the rider's
/// token, which a shared link never carried), says how to use it, then offers the share
/// sheet with the file itself. The file is thrown away when the sheet goes.
struct ExportFileSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let request: ExportRequest

    private enum Phase: Equatable {
        case loading
        case ready(URL)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var attempt = 0
    @State private var file = DownloadedFile()

    var body: some View {
        let copy = request.copy
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Text(copy.title)
                        .font(Theme.Typography.voice(26, relativeTo: .title))
                        .foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34) { dismiss() }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("export.close")
                }
                if let intro = copy.intro {
                    Text(intro)
                        .font(Theme.Typography.text(15))
                        .foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !copy.steps.isEmpty { steps(copy.steps) }
                if let note = copy.note {
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("export.note")
                }
                action
            }
            .padding(22)
        }
        .background(Theme.Colors.cream.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: attempt) { await download() }
    }

    private func steps(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(index + 1).")
                        .font(Theme.Typography.text(15, .bold))
                        .foregroundStyle(Theme.Colors.terracottaDeep)
                    Text(step)
                        .font(Theme.Typography.text(15))
                        .foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .accessibilityIdentifier("export.steps")
    }

    @ViewBuilder
    private var action: some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().tint(Theme.Colors.terracotta)
                Text("Getting the file…").font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Theme.Layout.primaryButtonHeight)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("export.loading")
        case .ready(let url):
            ShareLink(item: url) {
                Label("Share file", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.primary)
            .accessibilityIdentifier("export.share")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                ErrorLine(text: message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("export.error")
                Button("Try again") { attempt += 1 }
                    .buttonStyle(.secondaryWide)
                    .accessibilityIdentifier("export.retry")
            }
        }
    }

    private func download() async {
        phase = .loading
        do {
            let url: URL
            switch request {
            case .garminCourse(let id): url = try await container.api.downloadRouteExport(id: id, format: .fit)
            case .garminActivity(let id, _): url = try await container.api.downloadRideExport(id: id, format: .fit)
            case .gpx(let id, _): url = try await container.api.downloadRideExport(id: id, format: .gpx)
            }
            // Closed while it came: nothing will share it.
            guard !Task.isCancelled else { return ExportFile.discard(url) }
            file.url = url
            phase = .ready(url)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Holds the sheet's file for as long as the sheet is there and deletes it after. Tied
/// to the sheet's state rather than `onDisappear`, so the share sheet rising over it
/// can never take the file away mid-share.
private final class DownloadedFile {
    var url: URL? {
        didSet { if oldValue != url { ExportFile.discard(oldValue) } }
    }

    deinit { ExportFile.discard(url) }
}
