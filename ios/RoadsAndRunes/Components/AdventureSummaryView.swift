import RoadsAndRunesCore
import SwiftUI

/// Adventure Complete (design 13b): the ride's newly opened territory glows on
/// the ink world first; rewards slide up beneath. Cycling stats stay one quiet
/// line (spec §40).
struct AdventureSummaryView: View {
    @Environment(AppContainer.self) private var container
    let summary: AdventureSummary
    let units: Units
    let onDone: () -> Void
    @State private var geometry: RideGeometry?
    @State private var offerStrava = false
    @State private var stravaState: StravaLineState = .idle

    private enum StravaLineState { case idle, sending, sent, failed(String) }

    @ViewBuilder
    private var stravaLine: some View {
        switch stravaState {
        case .sent:
            Label("Sent to Strava", systemImage: "checkmark.circle.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
        case .sending:
            Label("Sending to Strava…", systemImage: "arrow.up.circle").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        case .failed(let reason):
            Text("Strava: \(reason)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
        case .idle:
            if summary.ride.stravaUploadStatus == "UPLOADED" || summary.ride.stravaUploadStatus == "QUEUED" {
                Label("Sent to Strava", systemImage: "checkmark.circle.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
            } else if offerStrava {
                Button {
                    stravaState = .sending
                    Task {
                        do { _ = try await container.api.uploadRideToStrava(rideId: summary.ride.id); stravaState = .sent }
                        catch { stravaState = .failed(error.localizedDescription) }
                    }
                } label: {
                    Label("Upload to Strava", systemImage: "arrow.up.circle")
                }
                .buttonStyle(.surfacePill)
            }
        }
    }

    /// Average H3 resolution-9 cell area, km².
    private static let cellAreaKm2 = 0.1053

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Colors.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    MapLibreView(
                        styleURL: Config.mapStyleURL(for: .minimal),
                        center: geometry?.path.first ?? summary.quest?.origin,
                        zoom: 12.5,
                        cells: [],
                        route: geometry?.path ?? [],
                        markers: markers
                    )
                    .ignoresSafeArea(edges: .top)
                    StatusPill(text: revealLine, dot: Theme.Colors.sageLight).padding(.top, 8)
                }
                .frame(height: 470)
                Spacer(minLength: 0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SheetHandle().frame(maxWidth: .infinity)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(text: "Adventure complete", color: Theme.Colors.sageDeep)
                            Text(summary.quest?.title ?? summary.ride.title ?? "Free ride")
                                .font(Theme.Typography.voice(28, relativeTo: .title))
                                .foregroundStyle(Theme.Colors.ink)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("+\(summary.xpAwarded.formatted())").font(Theme.Typography.text(40, .bold, relativeTo: .largeTitle))
                            Text("XP").font(Theme.Typography.text(14, .semibold))
                        }
                        .foregroundStyle(Theme.Colors.sageDeep)
                    }
                    if let coins = summary.acAwarded, coins > 0 {
                        HStack(spacing: 8) {
                            CoinPill(coins: coins, foreground: Theme.Colors.terracottaDeep)
                            Text(summary.walletBalance.map { "earned · \($0.formatted()) in your purse" } ?? "earned")
                                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                        .accessibilityIdentifier("summary.coins")
                    }
                    HStack(spacing: 8) {
                        FactTile(value: "\(summary.discoveries.count)", label: summary.discoveries.count == 1 ? "New place" : "New places")
                        FactTile(value: formatter.distance(meters: summary.newTerritoryMeters), label: "New territory")
                        FactTile(value: formatter.distance(meters: summary.newRoadsMeters), label: "New roads")
                    }
                    HStack {
                        Text("\(formatter.distance(meters: summary.ride.distanceMeters)) · \(formatter.duration(seconds: Double(summary.ride.durationSeconds))) · \(formatter.elevation(meters: summary.ride.elevationGainMeters)) climbed")
                        Spacer()
                        Text(xpSplit)
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.muted)
                    if summary.questCompletion != nil, let quest = summary.quest {
                        Text("Quest completed · all \(quest.requiredObjectives.count) objectives")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
                    }
                    if !unlocks.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(unlocks, id: \.self) { unlock in
                                Text(unlock)
                                    .font(Theme.Typography.captionStrong)
                                    .foregroundStyle(Theme.Colors.sageText)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.Colors.sageTint, in: Capsule())
                            }
                        }
                    }
                    if !summary.discoveries.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(summary.discoveries) { discovery in
                                Text(discovery.name)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.ink)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Theme.Colors.surface, in: Capsule())
                            }
                        }
                    }
                    if !summary.flags.isEmpty {
                        Text("Some data could not be validated: \(summary.flags.joined(separator: ", "))")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.terracottaDeep)
                    }
                    if summary.ride.healthKitWorkoutId != nil {
                        Label("Saved to Health", systemImage: "heart.fill").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.sageDeep)
                    }
                    stravaLine
                    Button("Collect rewards", action: onDone).buttonStyle(.primary).padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .frame(maxHeight: 460)
            .sheetSurface()
        }
        .task {
            // "Ask every time" is asked here, once, where the ride is fresh. "Automatically"
            // has already happened on the server by now; "Never" shows nothing.
            if container.session.user?.stravaUploadMode == .ask, summary.ride.stravaUploadStatus == nil,
               let status = try? await container.api.stravaStatus(), status.connected {
                offerStrava = true
            }
        }
        .task {
            geometry = try? await container.api.rideGeometry(id: summary.ride.id)
        }
    }

    private var markers: [MapMarker] {
        summary.discoveries.map { MapMarker(id: $0.id.uuidString, coordinate: $0.coordinate, kind: .discovery, title: $0.name) }
    }

    private var revealLine: String {
        let area = Double(summary.newCells) * Self.cellAreaKm2
        let areaText = area >= 10 ? "\(Int(area.rounded())) km²" : String(format: "%.1f km²", area)
        return "\(areaText) revealed · \(summary.newCells) new area\(summary.newCells == 1 ? "" : "s")"
    }

    private var xpSplit: String {
        let classXP = summary.xpBreakdown.filter { $0.source == "CLASS_BONUS" }.reduce(0) { $0 + $1.xp }
        let className = ClassStyle.name(container.session.character?.characterClass ?? .explorer)
        return "\(className) +\(classXP) · General +\(max(0, summary.xpAwarded - classXP))"
    }

    private var unlocks: [String] {
        var out: [String] = []
        for lu in summary.levelUps {
            out.append("\(lu.kind == .classLevel ? "Class level" : "Level") \(lu.from) → \(lu.to)")
        }
        out += summary.abilitiesUnlocked.map { "\($0.name) available" }
        out += (summary.titlesUnlocked ?? []).map { "Title: \($0)" }
        for taken in summary.worldObjects?.claimed ?? [] {
            let verb = taken.kind == .monster ? "Beat" : (taken.kind == .chest ? "Opened" : "Found")
            out.append("\(verb) \(taken.name) · +\(taken.rewardAC) AC")
        }
        for missed in summary.worldObjects?.missed ?? [] where missed.kind == .monster && missed.reason == "UNBEATEN" {
            out.append("\(missed.name) shrugged it off")
        }
        if let streak = summary.streak, streak.extended {
            let days = "\(streak.days) day\(streak.days == 1 ? "" : "s") in a row"
            out.append(streak.milestone != nil ? "\(days) · milestone · +\(streak.bonusAC) AC" : "\(days) · +\(streak.bonusAC) AC")
        }
        return out
    }
}
