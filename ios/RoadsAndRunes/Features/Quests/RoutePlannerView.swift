import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class RoutePlannerViewModel {
    var request = ""
    var distanceKm: Double
    var selectedBike: Bike?
    private(set) var bikes: [Bike] = []
    private(set) var alternatives: [RouteOption] = []
    private(set) var selected: RouteOption?
    /// One camera per decision, so the preview map moves when the rider picks a
    /// route or a stop and stays put while the rest of the sheet redraws.
    private(set) var preview: MapCamera?
    private(set) var focusedStop: RoutePOI?
    private(set) var isGenerating = false
    private(set) var isStarting = false
    private(set) var engine: String?
    /// What the planner made of the request ("Notting Hill · 5 pubs · loop"), so a
    /// misread is visible instead of showing up as a route in the wrong place.
    private(set) var understood: String?
    var error: String?
    /// Quest rides open on the quest's fixed route; tweaking reveals the controls.
    var isTweaking = false
    private(set) var questRoute: RouteOption?
    let quest: Quest?
    /// Directions to a place picked on the World map (A → B instead of a loop).
    let destination: Place?
    private let container: AppContainer

    init(quest: Quest?, destination: Place? = nil, container: AppContainer) {
        self.quest = quest
        self.destination = destination
        self.container = container
        if let destination, let here = container.location.lastFix?.coordinate {
            distanceKm = max(2, (GeoMath.distance(here, destination.coordinate) / 1000 * 1.3).rounded())
        } else {
            distanceKm = quest?.recommendedDistanceKm ?? 25
        }
    }

    var showsControls: Bool { quest == nil || isTweaking }

    var routesHeading: String {
        if quest != nil { return alternatives.count > 1 ? "Ways to ride it" : "The route" }
        return destination == nil ? "Three ways to ride it" : "Ways to get there"
    }

    var units: Units { container.session.units }

    /// Highest-scoring alternative: the "Best match" badge.
    var bestMatchId: UUID? { alternatives.filter { $0.id != questRoute?.id }.max { $0.score < $1.score }?.id }

    /// A custom adventure is named after what the rider asked for, else the
    /// chosen route's label; quest rides carry the quest title instead.
    var adventureTitle: String? {
        guard quest == nil, let selected else { return nil }
        if let destination { return "Ride to \(destination.name)" }
        let asked = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return "\(selected.label) ride" }
        return String((asked.prefix(1).uppercased() + asked.dropFirst()).prefix(120))
    }

    /// Reads the server's loosely-typed parse back into one line a rider can check.
    static func understood(from parsed: [String: JSONValue]?) -> String? {
        guard let parsed else { return nil }
        var parts: [String] = []
        if let area = parsed["area"]?.objectValue, let name = (area["name"] ?? area["query"])?.stringValue {
            parts.append(name)
        }
        if let poi = parsed["poi"]?.objectValue {
            // "3 cafes or something cultural" parses to two kinds of stop.
            let listed = poi["categories"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let kinds = (listed.isEmpty ? [poi["category"]?.stringValue].compactMap { $0 } : listed).map { $0.lowercased() }
            let stops = poi["count"]?.intValue
            if kinds.count > 1 {
                parts.append(stops.map { "\($0) stops" } ?? "stops")
                parts.append(kinds.joined(separator: " or "))
            } else if let kind = kinds.first {
                parts.append(stops.map { "\($0) \(kind)\($0 == 1 ? "" : "s")" } ?? kind)
            }
        }
        if let distance = parsed["distanceKm"]?.objectValue?["target"]?.doubleValue {
            parts.append("\(Int(distance)) km")
        }
        if parsed["loop"]?.boolValue == true { parts.append("loop") }
        // Five cafés asked for and two in the area: say so, rather than leaving the
        // rider to count the pins and wonder what went wrong.
        if let asked = parsed["poi"]?.objectValue?["count"]?.intValue,
           let found = parsed["stops"]?.arrayValue?.count, found < asked {
            parts.append(found == 0 ? "none found nearby" : "only \(found) found nearby")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func loadBikes() async {
        bikes = (try? await container.api.bikes()) ?? []
        selectedBike = bikes.first { $0.isDefault } ?? bikes.first
    }

    func append(preset: String) {
        request = request.isEmpty ? preset : "\(request), \(preset.lowercased())"
    }

    /// Picking a route fits the preview map to it and closes whatever stop was open.
    func choose(_ route: RouteOption?) {
        selected = route
        focusedStop = nil
        preview = route.map { MapCamera(fit: $0.path, padding: Self.previewPadding) }
    }

    /// A stop tapped on the map is read where it is; one tapped in the list below is
    /// brought into view first. Tapping it again closes it and refits the route.
    func focus(_ poi: RoutePOI?, moveCamera: Bool = false) {
        focusedStop = poi
        if let poi {
            if moveCamera { preview = MapCamera(center: poi.coordinate, zoom: 15.5) }
        } else if let selected {
            preview = MapCamera(fit: selected.path, padding: Self.previewPadding)
        }
    }

    private static let previewPadding = UIEdgeInsets(top: 26, left: 22, bottom: 46, right: 22)

    /// Quest rides start from the quest's fixed route; everything else plans fresh.
    func prepare() async {
        guard let quest else { return await generate() }
        do {
            let route = try await container.api.questRoute(id: quest.id)
            questRoute = route
            alternatives = [route]
            choose(route)
            engine = route.engine
            error = nil
        } catch {
            await generate()
        }
    }

    func generate() async {
        guard let origin = container.location.lastFix?.coordinate ?? quest?.origin else {
            error = "Waiting for your location"
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        do {
            let response = try await container.api.generateRoutes(RouteGenerateRequest(
                origin: origin, destination: destination?.coordinate, bikeId: selectedBike?.id, questId: quest?.id,
                distanceTargetKm: distanceKm, loop: destination == nil, request: request.isEmpty ? nil : request
            ))
            // The quest's own route stays first so the rider can always go back to it.
            alternatives = (questRoute.map { [$0] } ?? []) + response.alternatives
            engine = response.engine
            understood = Self.understood(from: response.parsedRequest)
            let fresh = response.alternatives
            choose(fresh.first { $0.label == "Adventure" } ?? fresh.max { $0.score < $1.score } ?? alternatives.first)
            error = nil
            container.analytics.track(.routeGenerated, properties: ["count": String(alternatives.count), "engine": response.engine ?? "unknown"])
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Accepts the quest if needed, downloads the package and starts the ride (spec §96 steps 12–13).
    func startRide() async -> Bool {
        guard let selected else { return false }
        isStarting = true
        defer { isStarting = false }
        do {
            var quest = self.quest
            if let q = quest, q.status == .available {
                quest = try await container.api.acceptQuest(id: q.id)
            }
            let package = try await container.api.routePackage(id: selected.id)
            container.analytics.track(.routeSelected, properties: ["routeId": selected.id.uuidString, "label": selected.label])
            if let quest { container.analytics.track(.questStarted, properties: ["questId": quest.id.uuidString]) }
            await container.rideRecorder.start(package: package, quest: quest ?? package.quest, bikeId: selectedBike?.id, title: adventureTitle)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

/// Plan (design 1a) → three ways to ride it (2a) → the chosen route's facts (3a)
/// → Start ride. One sheet, one primary action.
struct RoutePlannerView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: RoutePlannerViewModel?
    let quest: Quest?
    var destination: Place?

    private static let presets = ["Café ride", "Pub ride", "Easy", "Gravel", "Scenic", "Quiet roads"]

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Colors.cream.ignoresSafeArea()
            if let model { content(model) } else { ProgressView().tint(Theme.Colors.terracotta) }
        }
        .task {
            if model == nil { model = RoutePlannerViewModel(quest: quest, destination: destination, container: container) }
            await model?.loadBikes()
            if model?.alternatives.isEmpty == true { await model?.prepare() }
        }
    }

    @ViewBuilder
    private func content(_ model: RoutePlannerViewModel) -> some View {
        @Bindable var model = model
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    IconCircleButton(symbol: "xmark", background: Theme.Colors.surface) { dismiss() }.accessibilityLabel("Close").accessibilityIdentifier("planner.close")
                    Spacer()
                    if let quest = model.quest {
                        Eyebrow(text: "\(ClassStyle.name(quest.characterClass)) quest · \(quest.title)", color: ClassStyle.textColor(quest.characterClass))
                    } else {
                        Eyebrow(text: model.destination == nil ? "Your own adventure" : "Directions", color: Theme.Colors.terracottaDeep)
                    }
                }
                Text(title(model))
                    .font(Theme.Typography.voice(30, relativeTo: .largeTitle))
                    .foregroundStyle(Theme.Colors.ink)

                if model.showsControls {
                    VStack(spacing: 14) {
                        TextField("About 30 km, mostly quiet roads, easy gravel and a pub halfway.", text: $model.request, axis: .vertical)
                            .font(Theme.Typography.text(17))
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(2...4)
                        HStack {
                            HStack(spacing: 6) {
                                outlineChip("From here")
                                outlineChip(model.destination.map { "To \($0.name)" } ?? "Loop")
                            }
                            Spacer()
                            Button { Task { await model.generate() } } label: {
                                Group {
                                    if model.isGenerating {
                                        ProgressView().tint(Theme.Colors.cream)
                                    } else {
                                        Image(systemName: "arrow.right").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.Colors.cream)
                                    }
                                }
                                .frame(width: 48, height: 48)
                                .background(Theme.Colors.terracotta, in: Circle())
                            }
                            .buttonStyle(.pressable)
                            .disabled(model.isGenerating)
                            .accessibilityLabel("Generate routes")
                        }
                    }
                    .padding(18)
                    .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

                    FlowLayout(spacing: 8) {
                        ForEach(Self.presets, id: \.self) { preset in
                            Button(preset) { model.append(preset: preset) }.buttonStyle(.surfacePill)
                        }
                    }

                    HStack(spacing: 12) {
                        if model.destination == nil {
                            Text("\(Int(model.distanceKm)) km").font(Theme.Typography.label).foregroundStyle(Theme.Colors.ink).frame(width: 56, alignment: .leading)
                            Slider(value: $model.distanceKm, in: 5...150, step: 1).tint(Theme.Colors.terracotta)
                        } else {
                            Spacer()
                        }
                        if !model.bikes.isEmpty {
                            Picker("Bike", selection: $model.selectedBike) {
                                ForEach(model.bikes) { bike in Text(bike.name).tag(Optional(bike)) }
                            }
                            .pickerStyle(.menu)
                            .tint(Theme.Colors.terracottaDeep)
                        }
                    }
                }
                if let error = model.error { ErrorLine(text: error) }

                if !model.alternatives.isEmpty {
                    SectionHeader(title: model.routesHeading, subtitle: model.engine == "synthetic" ? "preview routing" : nil)
                    if let understood = model.understood {
                        Label(understood, systemImage: "text.magnifyingglass")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.muted)
                            .accessibilityIdentifier("planner.understood")
                    }
                    ForEach(model.alternatives) { route in
                        Button { withAnimation(.snappy) { model.choose(route) } } label: {
                            RouteCard(
                                route: route, selected: model.selected?.id == route.id, units: model.units,
                                bestMatch: model.bestMatchId == route.id, badge: route.id == model.questRoute?.id ? "Quest route" : nil
                            )
                        }
                        .buttonStyle(.pressable)
                    }
                    if !model.showsControls {
                        Button { withAnimation(.snappy) { model.isTweaking = true } } label: {
                            Label("Tweak the route", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.secondaryWide)
                    }
                    if let selected = model.selected {
                        RouteDetailPanel(
                            route: selected,
                            units: model.units,
                            camera: model.preview,
                            focused: model.focusedStop,
                            onFocus: { poi, moveCamera in withAnimation(.snappy) { model.focus(poi, moveCamera: moveCamera) } },
                            onClearStop: { withAnimation(.snappy) { model.focus(nil) } }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, model.selected == nil ? 24 : 130)
        }
        if model.selected != nil {
            VStack(spacing: 8) {
                Label("Map, directions, elevation and stops download when you start", systemImage: "arrow.down.circle")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                Button {
                    Task { if await model.startRide() { dismiss() } }
                } label: {
                    HStack(spacing: 10) {
                        if model.isStarting { ProgressView().tint(Theme.Colors.cream) } else { Image(systemName: "play.fill") }
                        Text(model.isStarting ? "Downloading route…" : "Start ride")
                    }
                }
                .buttonStyle(.primary)
                .disabled(model.isStarting || container.rideRecorder.isActive)
                .accessibilityIdentifier("planner.start")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(LinearGradient(colors: [Theme.Colors.cream.opacity(0), Theme.Colors.cream], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        }
    }

    private func title(_ model: RoutePlannerViewModel) -> String {
        if model.quest != nil { return model.isTweaking ? "How do you want\nto ride it?" : "Your quest\nroute" }
        if let destination = model.destination { return "Ride to\n\(destination.name)" }
        return "What kind of ride\ntoday?"
    }

    private func outlineChip(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.text(12))
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(Capsule().stroke(Theme.Colors.ink.opacity(0.16), lineWidth: 1))
    }
}

/// The chosen route's facts (design 3a): four tiles, the elevation profile with
/// the longest climb highlighted, then the stops.
struct RouteDetailPanel: View {
    let route: RouteOption
    let units: Units
    var camera: MapCamera?
    var focused: RoutePOI?
    /// A stop, and whether the map should move to it (true from the list, false from
    /// a marker the rider is already looking at).
    var onFocus: (RoutePOI, Bool) -> Void = { _, _ in }
    var onClearStop: () -> Void = {}

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RouteMapPreview(
                route: route,
                camera: camera,
                focused: focused,
                units: units,
                onSelect: { onFocus($0, false) },
                onClearFocus: onClearStop
            )
            HStack(spacing: 8) {
                FactTile(value: formatter.distance(meters: route.distanceMeters), label: "Distance")
                FactTile(value: formatter.duration(seconds: Double(route.estimatedDurationSeconds)), label: "At your pace")
                FactTile(value: formatter.elevation(meters: route.elevationGainMeters), label: "Climbing")
                FactTile(value: "\(Int((route.surface.gravel + route.surface.trail) * 100))%", label: "Gravel")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Elevation").font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    Text("Highest \(formatter.elevation(meters: route.highestPointMeters)) · steepest \(Int(route.maxGradientPercent.rounded()))%")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
                ElevationSparkline(samples: route.elevationSamples, highlight: route.longestClimb).frame(height: 72)
                HStack {
                    Text("0")
                    Spacer()
                    Text(formatter.distance(meters: route.distanceMeters / 2))
                    Spacer()
                    Text(formatter.distance(meters: route.distanceMeters))
                }
                .font(Theme.Typography.text(10, relativeTo: .caption2)).foregroundStyle(Theme.Colors.mutedLight)
            }
            if let climb = route.longestClimb {
                HStack {
                    Label("Longest climb \(formatter.distance(meters: climb.lengthMeters)) · \(String(format: "%.1f", climb.averageGradientPercent))% avg", systemImage: "arrow.up.right")
                    Spacer()
                    Text("at \(formatter.distance(meters: climb.startMeters))")
                }
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            if !route.pois.isEmpty {
                Text("Stops on the way")
                    .font(Theme.Typography.text(13, .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.top, 2)
            }
            ForEach(route.pois.prefix(6)) { poi in
                Button {
                    if poi.id == focused?.id { onClearStop() } else { onFocus(poi, true) }
                } label: {
                    RouteStopRow(poi: poi, units: units, selected: poi.id == focused?.id)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("routeStop")
            }
        }
    }
}
