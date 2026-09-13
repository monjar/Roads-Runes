import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class RoutePlannerViewModel {
    var request = ""
    var distanceKm: Double
    /// Ride, run or walk this one; starts as the player's usual.
    var activity: Activity
    var selectedBike: Bike?
    private(set) var bikes: [Bike] = []
    private(set) var alternatives: [RouteOption] = []
    private(set) var selected: RouteOption?
    /// One camera per decision, so the preview map moves when the rider picks a
    /// route or a stop and stays put while the rest of the sheet redraws.
    private(set) var preview: MapCamera?
    private(set) var focusedStop: RoutePOI?
    private(set) var isGenerating = false
    /// What the planner is doing while the rider waits. A cold server plus a fresh
    /// area can take half a minute, and a silent spinner reads as "stuck".
    private(set) var planningStep: String?
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
        activity = quest?.activity.flatMap { $0 == .unknown ? nil : $0 } ?? container.session.defaultActivity
        if let destination, let here = container.location.lastFix?.coordinate {
            distanceKm = max(2, (GeoMath.distance(here, destination.coordinate) / 1000 * 1.3).rounded())
        } else {
            distanceKm = quest?.recommendedDistanceKm ?? 25
        }
    }

    var showsControls: Bool { quest == nil || isTweaking }

    var routesHeading: String {
        if quest != nil { return alternatives.count > 1 ? "Ways to \(activity.noun) it" : "The route" }
        return destination == nil ? "Three ways to \(activity.noun) it" : "Ways to get there"
    }

    var units: Units { container.session.units }

    /// The plain way there, when the planner offered one: the yardstick for what the
    /// other cards cost. The server labels it, and falls back to the shortest.
    private var plainest: RouteOption? {
        alternatives.first { $0.label == "Direct" }
            ?? alternatives.min { $0.distanceMeters < $1.distanceMeters }
    }

    /// "+4.2 km · +14 min for a café and 38% more gravel" — the trade the rider is
    /// making by taking this one, rather than leaving them to work it out.
    func tradeOff(for route: RouteOption) -> String? {
        guard let plainest, plainest.id != route.id else { return nil }
        let extraMeters = route.distanceMeters - plainest.distanceMeters
        let extraMinutes = (route.estimatedDurationSeconds - plainest.estimatedDurationSeconds) / 60
        guard extraMeters >= 250 else { return nil }
        var gains: [String] = []
        let stops = route.pois.filter { $0.requested == true }.count
        if stops > 0 { gains.append(stops == 1 ? "your stop" : "\(stops) stops") }
        let gravel = Int(((route.surface.gravel + route.surface.trail) - (plainest.surface.gravel + plainest.surface.trail)) * 100)
        if gravel >= 5 { gains.append("\(gravel)% more gravel") }
        let cycleways = Int((route.cyclewayFraction - plainest.cyclewayFraction) * 100)
        if gains.isEmpty && cycleways >= 8 { gains.append("\(cycleways)% more cycleway") }
        if gains.isEmpty && route.elevationGainMeters > plainest.elevationGainMeters * 1.3 { gains.append("more climbing") }
        guard !gains.isEmpty else { return nil }
        let formatter = UnitFormatter(units: units)
        let cost = extraMinutes >= 1
            ? "+\(formatter.distance(meters: extraMeters)) · +\(extraMinutes) min"
            : "+\(formatter.distance(meters: extraMeters))"
        return "\(cost) for \(gains.joined(separator: " and "))"
    }

    /// Highest-scoring alternative: the "Best match" badge.
    var bestMatchId: UUID? { alternatives.filter { $0.id != questRoute?.id }.max { $0.score < $1.score }?.id }

    /// A custom adventure is named after what the rider asked for, else the
    /// chosen route's label; quest rides carry the quest title instead.
    var adventureTitle: String? {
        guard quest == nil, let selected else { return nil }
        if let destination { return "\(activity.verb) to \(destination.name)" }
        let asked = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return "\(selected.label) ride" }
        return String((asked.prefix(1).uppercased() + asked.dropFirst()).prefix(120))
    }

    /// Reads the server's loosely-typed parse back into one line a rider can check.
    static func understood(from parsed: [String: JSONValue]?) -> String? {
        guard let parsed else { return nil }
        // The server says what it made of the request; older servers left it to us,
        // and we came up empty for "quiet roads", which names no place and no stop.
        var parts = (parsed["understood"]?.arrayValue ?? []).compactMap(\.stringValue)
        if parts.isEmpty { parts = legacyParts(of: parsed) }
        // What the ground could not give — no gravel here, nothing to climb, fewer
        // cafés than asked for. Better said than left for the rider to notice.
        parts += (parsed["notes"]?.arrayValue ?? []).compactMap { $0.stringValue }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func legacyParts(of parsed: [String: JSONValue]) -> [String] {
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
        return parts
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

    /// Opening a stop marks it on the map and in the list. The camera stays fitted
    /// to the route — every stop is on it, so there is nothing to travel to.
    func focus(_ poi: RoutePOI?) { focusedStop = poi }

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
        let narrator = Task { await narratePlanning() }
        defer {
            isGenerating = false
            narrator.cancel()
            planningStep = nil
        }
        do {
            let response = try await container.api.generateRoutes(RouteGenerateRequest(
                origin: origin, destination: destination?.coordinate, bikeId: activity == .ride ? selectedBike?.id : nil, questId: quest?.id,
                distanceTargetKm: distanceKm, loop: destination == nil, request: request.isEmpty ? nil : request,
                activity: activity
            ))
            // The quest's own route stays first so the rider can always go back to it.
            alternatives = (questRoute.map { [$0] } ?? []) + response.alternatives
            engine = response.engine
            // A typed request always gets an answer on screen, even from a server that
            // said nothing about it: silence looked like the request being ignored.
            understood = Self.understood(from: response.parsedRequest)
                ?? (request.isEmpty ? nil : "Planned as usual — couldn't read the request")
            // "a 12 km loop" beats a slider sitting at 25; move it to what was used.
            if let asked = response.parsedRequest?["distanceKm"]?.objectValue?["target"]?.doubleValue,
               (5...150).contains(asked) {
                distanceKm = asked.rounded()
            }
            let fresh = response.alternatives
            // The one that does what was asked comes first; without a request there is
            // no such card and the best-scoring flavour opens as before.
            choose(
                fresh.first { $0.label == "As asked" }
                    ?? fresh.first { $0.label == "Adventure" }
                    ?? fresh.max { $0.score < $1.score }
                    ?? alternatives.first
            )
            error = nil
            container.analytics.track(.routeGenerated, properties: ["count": String(alternatives.count), "engine": response.engine ?? "unknown"])
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func narratePlanning() async {
        planningStep = request.isEmpty ? "Drawing routes…" : "Reading your request…"
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        planningStep = request.isEmpty ? "Drawing routes…" : "Finding stops on the way…"
        try? await Task.sleep(for: .seconds(6))
        guard !Task.isCancelled else { return }
        planningStep = "Drawing routes…"
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
            await container.rideRecorder.start(package: package, quest: quest ?? package.quest, bikeId: activity == .ride ? selectedBike?.id : nil, title: adventureTitle, activity: activity)
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
    /// The request field is multi-line, so Return adds a line instead of dismissing
    /// the keyboard — which then covers the routes it just asked for.
    @FocusState private var writingRequest: Bool
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
                    Picker("Activity", selection: $model.activity) {
                        ForEach([Activity.ride, .run, .walk], id: \.self) { activity in
                            Text(activity.verb).tag(activity)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("planner.activity")
                    VStack(spacing: 14) {
                        TextField(model.activity == .ride ? "About 30 km, mostly quiet roads, easy gravel and a pub halfway." : "About 5 km, through a park, with a café at the end.", text: $model.request, axis: .vertical)
                            .font(Theme.Typography.text(17))
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(2...4)
                            .focused($writingRequest)
                            .submitLabel(.go)
                            .onChange(of: model.request) { _, text in
                                // Multi-line, so Return types a newline rather than submitting;
                                // a newline at the end is the rider pressing Go.
                                guard text.hasSuffix("\n") else { return }
                                model.request = String(text.dropLast())
                                writingRequest = false
                                Task { await model.generate() }
                            }
                        HStack {
                            HStack(spacing: 6) {
                                outlineChip("From here")
                                outlineChip(model.destination.map { "To \($0.name)" } ?? "Loop")
                            }
                            Spacer()
                            Button {
                                writingRequest = false
                                Task { await model.generate() }
                            } label: {
                                // A word on the button: an arrow in a circle was not read as
                                // "plan this", so the request sat there unplanned.
                                HStack(spacing: 8) {
                                    if model.isGenerating {
                                        ProgressView().tint(Theme.Colors.cream)
                                    } else {
                                        Image(systemName: "arrow.right").font(.system(size: 16, weight: .bold))
                                    }
                                    Text(model.isGenerating ? "Planning…" : "Plan")
                                        .font(Theme.Typography.text(15, .semibold))
                                }
                                .foregroundStyle(Theme.Colors.cream)
                                .padding(.horizontal, 18)
                                .frame(height: 48)
                                .background(Theme.Colors.terracotta, in: Capsule())
                            }
                            .buttonStyle(.pressable)
                            .disabled(model.isGenerating)
                            .accessibilityLabel("Generate routes")
                        }
                        if model.isGenerating, let step = model.planningStep {
                            Label(step, systemImage: "hourglass")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("planner.step")
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
                        if !model.bikes.isEmpty, model.activity == .ride {
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
                                bestMatch: model.bestMatchId == route.id,
                                badge: route.id == model.questRoute?.id ? "Quest route" : nil,
                                tradeOff: model.tradeOff(for: route)
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
                            onFocus: { poi in withAnimation(.snappy) { model.focus(poi) } },
                            onClearStop: { withAnimation(.snappy) { model.focus(nil) } }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, model.selected == nil ? 24 : 130)
        }
        .scrollDismissesKeyboard(.interactively)
        if model.selected != nil {
            VStack(spacing: 8) {
                Label("Map, directions, elevation and stops download when you start", systemImage: "arrow.down.circle")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                Button {
                    Task { if await model.startRide() { dismiss() } }
                } label: {
                    HStack(spacing: 10) {
                        if model.isStarting { ProgressView().tint(Theme.Colors.cream) } else { Image(systemName: "play.fill") }
                        Text(model.isStarting ? "Downloading route…" : "Start \(model.activity.noun)")
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
        if let destination = model.destination { return "\(model.activity.verb) to\n\(destination.name)" }
        return "What kind of \(model.activity.noun)\ntoday?"
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
    var onFocus: (RoutePOI) -> Void = { _ in }
    var onClearStop: () -> Void = {}

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RouteMapPreview(
                route: route,
                camera: camera,
                focused: focused,
                units: units,
                onSelect: onFocus,
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
                    if poi.id == focused?.id { onClearStop() } else { onFocus(poi) }
                } label: {
                    RouteStopRow(poi: poi, units: units, selected: poi.id == focused?.id)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("routeStop")
                .accessibilityValue(poi.category.rawValue.lowercased())
            }
        }
    }
}
