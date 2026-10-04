import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Active navigation (design 4a/12a): instruction card on cream over the map,
/// the quest as a second, quieter ink line, three stats in an ink pill.
/// Objective complete (12b) and off route (4c) replace the instruction card;
/// paused (8d) replaces the stats pill. No XP animation while moving (spec §33).
struct NavigationScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var confirmingEnd = false
    /// A stop tapped on the map, read without leaving the ride.
    @State private var readingStop: RoutePOI?

    private var recorder: RideRecorder { container.rideRecorder }
    private var formatter: UnitFormatter { UnitFormatter(units: container.session.units) }

    var body: some View {
        ZStack {
            MapLibreView(
                styleURL: Config.mapStyleURL(for: .minimal),
                center: recorder.lastFix?.coordinate ?? recorder.package?.route.path.first,
                // Riding is read at arm's length: close enough to see the next turning.
                zoom: 16.5,
                cells: [],
                route: recorder.package?.route.path ?? [],
                guide: guide,
                markers: markers,
                followsUser: true,
                navigationMode: true,
                onMarkerTap: { marker in
                    guard let poi = recorder.package?.pois.first(where: { "stop-\($0.discoveryId.uuidString)" == marker.id }) else { return }
                    withAnimation(.snappy) { readingStop = poi }
                }
            )
            .ignoresSafeArea()
            VStack(spacing: 8) {
                topCard
                if recorder.recentReroute {
                    MapPill(text: "New route from here")
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("reroutedPill")
                } else if let notice = recorder.notice {
                    // What the chime was for, for a rider who happens to be looking.
                    MapPill(text: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("rideNotice")
                }
                if recorder.recentObjectiveCompletion != nil, let instruction = recorder.progress?.nextInstruction {
                    MapPill(text: "\(TurnArrowView.phrase(for: instruction.sign)) · \(formatter.distance(meters: recorder.progress?.distanceToNextInstruction ?? instruction.distanceMeters))")
                } else {
                    ObjectiveBanner(objective: recorder.currentObjective, quest: recorder.quest, title: recorder.title ?? LoreCopy.free(recorder.activity),
                                    position: recorder.lastFix?.coordinate, formatter: formatter)
                }
                if let stop = recorder.nearbyStop {
                    NearbyStopCard(
                        poi: stop,
                        distanceMeters: recorder.lastFix.map { GeoMath.distance($0.coordinate, stop.coordinate) },
                        formatter: formatter
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let claim = recorder.recentClaim {
                    ClaimToast(object: claim)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                if let encounter = recorder.encounter {
                    EncounterBanner(status: encounter, formatter: formatter, isStill: recorder.isStill,
                                    wordReach: container.session.config?.combat?.wordRadiusMeters ?? 120) { note in
                        recorder.complete(encounter: encounter.object, note: note, photoTaken: false)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let objective = recorder.currentObjective, objective.needsRider {
                    ScribeActions(objective: objective) { note in
                        Task { await recorder.complete(objective: objective, note: note) }
                    } onPhoto: { data in
                        Task { await recorder.complete(objective: objective, photo: data) }
                    }
                }
                HStack {
                    StatusPill(
                        text: container.watch.isReachable ? "Watch · navigating" : "Watch off",
                        dot: container.watch.isReachable ? Theme.Colors.sageLight : Theme.Colors.mutedLight,
                        foreground: container.watch.isReachable ? Theme.Colors.cream : Theme.Colors.line
                    )
                    Spacer()
                    if container.location.accuracyPoor {
                        StatusPill(text: "GPS is weak", dot: Theme.Colors.terracottaLight)
                    }
                }
                .padding(.horizontal, 2)
                Spacer(minLength: 0)
                if let readingStop {
                    StopCallout(poi: readingStop, units: container.session.units) {
                        withAnimation(.snappy) { self.readingStop = nil }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if recorder.state == .paused {
                    pausedPill
                } else {
                    statsPill
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .background(Theme.Colors.cream.ignoresSafeArea())
        .confirmationDialog("End this \(journey)?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("Save \(journey)") { Task { await recorder.finish() } }
                .accessibilityIdentifier("ride.save")
            Button("Discard \(journey)", role: .destructive) { recorder.discard() }
                .accessibilityIdentifier("ride.discard")
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("\(formatter.distance(meters: recorder.stats.distanceMeters)) · \(formatter.duration(seconds: recorder.stats.elapsedSeconds)) · saved to Health")
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder
    private var topCard: some View {
        if let objective = recorder.recentObjectiveCompletion {
            ObjectiveCompleteCard(objective: objective, remaining: remainingObjectives)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if isOffRoute {
            OffRouteCard(
                rerouting: recorder.isRerouting || recorder.state == .rerouting,
                rejoin: recorder.rejoin,
                failure: recorder.rerouteError,
                formatter: formatter,
                onReroute: { recorder.rerouteNow() }
            )
        } else {
            TurnCard(progress: recorder.progress, route: recorder.package?.route, state: recorder.state, formatter: formatter, activity: recorder.activity)
        }
    }

    /// "ride", "run" or "walk": what the screen calls the journey under way.
    private var journey: String { LoreCopy.journey(recorder.activity) }

    private var isOffRoute: Bool {
        recorder.state == .offRoute || recorder.state == .rerouting || recorder.isRerouting
    }

    /// Off the route, a dashed line from the rider to the nearest of what is left of
    /// it: the way back, drawn, with or without a new route to follow.
    private var guide: [Coordinate] {
        guard isOffRoute, let here = recorder.lastFix?.coordinate, let rejoin = recorder.rejoin else { return [] }
        return [here, rejoin.point]
    }

    private var remainingObjectives: Int {
        guard let quest = recorder.quest else { return 0 }
        return quest.requiredObjectives.filter { !recorder.completedObjectiveIDs.contains($0.id) && $0.status != .completed }.count
    }

    private var statsPill: some View {
        HStack(spacing: 0) {
            NavMetric(title: "\(formatter.distanceUnitLabel) \(LoreCopy.travelled(recorder.activity))", value: formatter.distanceValue(meters: recorder.stats.distanceMeters).formatted(.number.precision(.fractionLength(1))))
            NavMetric(title: "\(formatter.distanceUnitLabel) newly explored", value: formatter.distanceValue(meters: recorder.newTerritoryMeters).formatted(.number.precision(.fractionLength(1))), accent: true, alignment: .center)
                .padding(.horizontal, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.Colors.cream.opacity(0.15)).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.Colors.cream.opacity(0.15)).frame(width: 1) }
            NavMetric(title: "time", value: formatter.duration(seconds: recorder.stats.elapsedSeconds), alignment: .trailing)
            Button { recorder.pause() } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.Colors.cream)
                    .frame(width: 48, height: 48)
                    .background(Theme.Colors.inkSoft, in: Circle())
            }
            .buttonStyle(.pressable)
            .padding(.leading, 18)
            .accessibilityLabel("Pause \(journey)")
            .accessibilityIdentifier("ride.pause")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(alignment: .top) { routeProgress }
        .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 16, y: 12)
    }

    /// How much of the route is behind, as a thin line along the top of the pill, and
    /// how far is left. Only on the route: off it, "to go" is not a number anyone has.
    @ViewBuilder
    private var routeProgress: some View {
        if let progress = recorder.progress, recorder.state == .active, (recorder.package?.route.distanceMeters ?? 0) > 0 {
            VStack(spacing: 5) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.Colors.cream.opacity(0.14))
                        Capsule().fill(Theme.Colors.sageLight).frame(width: max(4, geometry.size.width * progress.fractionComplete))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 26)
                Text("\(formatter.distance(meters: progress.distanceRemaining)) to go")
                    .font(Theme.Typography.text(10.5, .semibold, relativeTo: .caption2))
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, 9).padding(.vertical, 2)
                    .background(Theme.Colors.sageLight, in: Capsule())
                    .offset(y: -15)
            }
            .offset(y: 5)
            .animation(.easeOut(duration: 0.6), value: progress.fractionComplete)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(formatter.distance(meters: progress.distanceRemaining)) to go")
            .accessibilityIdentifier("ride.toGo")
        }
    }

    /// Ride paused (design 8d): auto-pause explained, Resume is huge, End beside it.
    private var pausedPill: some View {
        VStack(spacing: 14) {
            HStack {
                Eyebrow(text: "Paused", color: Theme.Colors.line)
                Spacer()
                Text("Still recording · resumes when you move").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.line)
            }
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(formatter.distanceValue(meters: recorder.stats.distanceMeters).formatted(.number.precision(.fractionLength(1)))).font(Theme.Typography.text(26, .bold))
                    Text(formatter.distanceUnitLabel).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.line)
                }
                Text(formatter.duration(seconds: recorder.stats.elapsedSeconds)).font(Theme.Typography.text(26, .bold).monospacedDigit())
                Spacer()
            }
            .foregroundStyle(Theme.Colors.cream)
            HStack(spacing: 10) {
                Button { recorder.resume() } label: {
                    HStack(spacing: 8) { Image(systemName: "play.fill"); Text("Resume \(journey)") }
                }
                .buttonStyle(.sage)
                .accessibilityIdentifier("ride.resume")
                .frame(maxWidth: .infinity)
                Button { confirmingEnd = true } label: {
                    Text("End \(journey)")
                        .font(Theme.Typography.buttonSmall)
                        .foregroundStyle(Theme.Colors.terracottaLight)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Theme.Colors.inkSoft, in: Capsule())
                }
                .buttonStyle(.pressable)
                .frame(width: 120)
                .accessibilityIdentifier("ride.end")
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 16, y: 12)
    }

    private var markers: [MapMarker] {
        var out: [MapMarker] = []
        if let quest = recorder.quest {
            for objective in quest.objectives {
                if let coordinate = objective.coordinate {
                    let done = objective.status == .completed || recorder.completedObjectiveIDs.contains(objective.id)
                    out.append(MapMarker(id: objective.id.uuidString, coordinate: coordinate, kind: done ? .objectiveDone : .objective, title: objective.title))
                }
            }
        }
        // What is out there to be had: a chest was only a banner once it was 400 m off,
        // and the first the rider knew of it was riding past.
        for object in recorder.objectsOnMap {
            out.append(MapMarker(
                id: "object-\(object.id.uuidString)", coordinate: object.coordinate,
                kind: WorldViewModel.markerKind(for: object), title: object.name, mark: .of(object)
            ))
        }
        // The cafés, pubs and landmarks on the route, as what they are rather than as
        // anonymous dots, and tappable for their name and detour.
        for poi in recorder.package?.pois.prefix(12) ?? [] {
            out.append(MapMarker(
                id: "stop-\(poi.discoveryId.uuidString)",
                coordinate: poi.coordinate,
                kind: poi.discoveryId == readingStop?.discoveryId ? .stopActive : .stop,
                title: poi.name,
                mark: DiscoveryIcon.mark(for: poi.category)
            ))
        }
        return out
    }
}

/// Instruction card on cream: huge distance and arrow, the manoeuvre, the street.
struct TurnCard: View {
    let progress: ProgressUpdate?
    let route: RouteOption?
    let state: NavigationState
    let formatter: UnitFormatter
    /// Ride, run or walk, for "Free run"; nil says "Free journey".
    var activity: Activity?

    var body: some View {
        HStack(spacing: 18) {
            if let instruction = progress?.nextInstruction {
                TurnArrowView(sign: instruction.sign)
                VStack(alignment: .leading, spacing: 4) {
                    let parts = split(formatter.distance(meters: progress?.distanceToNextInstruction ?? instruction.distanceMeters))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(parts.value).font(Theme.Typography.numberHero.monospacedDigit()).foregroundStyle(Theme.Colors.ink).lineLimit(1).minimumScaleFactor(0.6)
                        Text(parts.unit).font(Theme.Typography.text(24, .semibold)).foregroundStyle(Theme.Colors.ink)
                    }
                    Text(TurnArrowView.phrase(for: instruction.sign)).font(Theme.Typography.text(18, .semibold)).foregroundStyle(Theme.Colors.ink)
                    if let detail = detailLine(street: instruction.streetName, text: instruction.text, sign: instruction.sign) {
                        Text(detail)
                            .font(Theme.Typography.text(15)).foregroundStyle(Theme.Colors.muted).lineLimit(2).minimumScaleFactor(0.8)
                    }
                }
                Spacer(minLength: 0)
                if let next = route?.instructions.first(where: { $0.index > instruction.index }) {
                    VStack(spacing: 2) {
                        Image(systemName: TurnArrowView.symbol(for: next.sign)).font(.system(size: 18, weight: .bold))
                        Text("then \(formatter.distance(meters: next.distanceMeters))").font(Theme.Typography.text(10, relativeTo: .caption2))
                    }
                    .foregroundStyle(Theme.Colors.muted)
                }
            } else {
                Image(systemName: state == .paused ? "pause.fill" : "location.north.line.fill").font(.system(size: 40, weight: .bold)).foregroundStyle(Theme.Colors.ink).frame(width: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state == .paused ? "Paused" : (route == nil ? LoreCopy.free(activity) : "Follow the route")).font(Theme.Typography.text(24, .bold)).foregroundStyle(Theme.Colors.ink)
                    Text(route == nil ? "Every new road counts." : "Directions start at the first turn.").font(Theme.Typography.text(15)).foregroundStyle(Theme.Colors.muted)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 6)
    }

    /// The street to turn onto; otherwise the engine's text only when it says more than the
    /// arrow does ("Turn right" under "Turn right" is noise on unnamed paths).
    private func detailLine(street: String, text: String, sign: InstructionSign) -> String? {
        if !street.isEmpty { return street }
        return text.caseInsensitiveCompare(TurnArrowView.phrase(for: sign)) == .orderedSame ? nil : text
    }

    private func split(_ distance: String) -> (value: String, unit: String) {
        guard let space = distance.lastIndex(of: " ") else { return (distance, "") }
        return (String(distance[..<space]), String(distance[distance.index(after: space)...]))
    }
}

struct TurnArrowView: View {
    let sign: InstructionSign

    var body: some View {
        Image(systemName: Self.symbol(for: sign))
            .font(.system(size: 56, weight: .bold))
            .foregroundStyle(Theme.Colors.ink)
            .frame(width: 72)
            .accessibilityLabel(Self.phrase(for: sign))
    }

    static func symbol(for sign: InstructionSign) -> String {
        switch sign {
        case .continue: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.turn.down.left"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.turn.down.right"
        case .uTurn: return "arrow.uturn.left"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .finish: return "flag.checkered"
        case .waypoint: return "mappin"
        case .unknown: return "arrow.up"
        }
    }

    static func word(for sign: InstructionSign) -> String {
        switch sign {
        case .continue: return "STRAIGHT"
        case .slightLeft: return "SLIGHT LEFT"
        case .left: return "LEFT"
        case .sharpLeft: return "SHARP LEFT"
        case .slightRight: return "SLIGHT RIGHT"
        case .right: return "RIGHT"
        case .sharpRight: return "SHARP RIGHT"
        case .uTurn: return "U-TURN"
        case .roundabout: return "ROUNDABOUT"
        case .finish: return "FINISH"
        case .waypoint: return "WAYPOINT"
        case .unknown: return "CONTINUE"
        }
    }

    static func phrase(for sign: InstructionSign) -> String {
        switch sign {
        case .continue: return "Continue straight"
        case .slightLeft: return "Bear left"
        case .left: return "Turn left"
        case .sharpLeft: return "Sharp left"
        case .slightRight: return "Bear right"
        case .right: return "Turn right"
        case .sharpRight: return "Sharp right"
        case .uTurn: return "Turn around"
        case .roundabout: return "At the roundabout"
        case .finish: return "Arrive"
        case .waypoint: return "Waypoint"
        case .unknown: return "Continue"
        }
    }
}

/// A stop the rider asked for, close enough to turn into. Sage, because arriving
/// where you meant to is good news, and the distance is big enough to read while
/// moving. It goes away once they have been within sixty metres of it.
struct NearbyStopCard: View {
    let poi: RoutePOI
    var distanceMeters: Double?
    let formatter: UnitFormatter

    var body: some View {
        HStack(spacing: 12) {
            MarkView(DiscoveryIcon.mark(for: poi.category))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(poi.name)
                    .font(Theme.Typography.text(15, .bold))
                    .foregroundStyle(Theme.Colors.cream)
                    .lineLimit(1)
                Text("the \(poi.category.rawValue.lowercased()) you asked for")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.cream.opacity(0.85))
            }
            Spacer(minLength: 8)
            if let distanceMeters {
                Text(formatter.distance(meters: distanceMeters))
                    .font(Theme.Typography.text(17, .bold).monospacedDigit())
                    .foregroundStyle(Theme.Colors.cream)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.Colors.sage, in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.2), radius: 8, y: 4)
        .accessibilityIdentifier("nearbyStop")
    }
}

/// "Defeated: Bog Wraith · +150 coins", for a few seconds, the moment it happens.
struct ClaimToast: View {
    let object: WorldObject

    var body: some View {
        HStack(spacing: 10) {
            EncounterGlyph(object: object, size: 30)
            Text("\(verb): \(object.name)").font(Theme.Typography.text(15, .bold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
            Spacer(minLength: 6)
            Text(LoreCopy.earned(object.rewardAC)).font(Theme.Typography.text(15, .bold).monospacedDigit()).foregroundStyle(Theme.Colors.terracottaDeep)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
        .background(Theme.Colors.cream, in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.22), radius: 8, y: 4)
        .accessibilityIdentifier("claimToast")
    }

    private var verb: String {
        switch object.kind {
        case .monster: return "Defeated"
        case .chest: return "Opened"
        default: return "Found"
        }
    }
}

/// The nearest thing in the world and how the fight is going: "Bog Wraith · 120 m".
/// A creature fought by effort sits in a ring of its health, redrawn in tenths with no
/// numbers and no animation. Words under the name, and the note button, show
/// only at a standstill (Core `Stillness`): nothing to read while moving.
struct EncounterBanner: View {
    let status: EncounterStatus
    let formatter: UnitFormatter
    var isStill = false
    /// How near a note has to be written to strike.
    var wordReach: Double = 120
    var onNote: (String) -> Void = { _ in }
    @State private var writingNote = false

    private var loreMethod: KillMethod? { status.object.monster?.killMethods.first { $0.method == .lore } }

    /// The note button: a note, near a creature fought by effort; the old way, the Scribe's way past it.
    private var noteLabel: String? {
        guard isStill, status.object.kind == .monster else { return nil }
        if status.object.monster?.foughtByEffort == true {
            return status.distanceMeters <= wordReach ? "Write a note" : nil
        }
        guard let lore = loreMethod else { return nil }
        // This sheet takes words, not photographs: a way in that needs one is not offered,
        // and nothing is offered from further than the server would accept it.
        if lore.params["requires"]?.arrayValue?.contains(.string("photo")) == true { return nil }
        guard status.distanceMeters <= (lore.double("radiusMeters") ?? 120) * 1.5 else { return nil }
        return "Write a note"
    }

    private var line: String {
        if let wants = status.object.monster?.wants, status.object.monster?.foughtByEffort == true {
            return LoreCopy.weakTo(wants)
        }
        return status.hint ?? (status.object.kind == .chest ? "Pass close by to open it" : "Pass close by to pick it up")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let tenths = status.holdTenths {
                    HoldRing(tenths: tenths) { EncounterGlyph(object: status.object, size: 30) }
                } else {
                    EncounterGlyph(object: status.object, size: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.object.name).font(Theme.Typography.text(15, .bold)).foregroundStyle(Theme.Colors.cream).lineLimit(1)
                    if isStill {
                        Text(line)
                            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.cream.opacity(0.85)).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(formatter.distance(meters: status.distanceMeters))
                    .font(Theme.Typography.text(17, .bold).monospacedDigit()).foregroundStyle(Theme.Colors.cream)
            }
            if let progress = status.progress, status.hold == nil {
                ProgressView(value: min(1, max(0, progress))).tint(Theme.Colors.cream)
                    .accessibilityIdentifier("encounter.progress")
            }
            if let noteLabel {
                Button {
                    writingNote = true
                } label: {
                    Label(noteLabel, systemImage: "square.and.pencil")
                        .font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.ink)
                        .padding(.horizontal, 12).frame(height: 34).background(Theme.Colors.cream, in: Capsule())
                }
                .buttonStyle(.pressable)
                .sheet(isPresented: $writingNote) {
                    NoteSheet(title: status.object.name) { note in
                        onNote(note)
                        writingNote = false
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.Colors.terracottaDeep, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.2), radius: 8, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("encounter")
    }
}

/// Its health, as a ring round its face: whole when untouched, drawn in tenths, with
/// no numbers and no animation (docs/ROADMAP.md, 0.6.1).
struct HoldRing<Content: View>: View {
    let tenths: Int
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Circle().stroke(Theme.Colors.cream.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(10, tenths))) / 10)
                .stroke(Theme.Colors.cream, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            content
        }
        .frame(width: 40, height: 40)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Creature health")
        .accessibilityValue("\(max(0, min(10, tenths)) * 10) percent left")
        .accessibilityIdentifier("encounter.hold")
    }
}

/// The quest as a second, quieter line: diamond, "QUEST · objective", distance.
struct ObjectiveBanner: View {
    let objective: Objective?
    let quest: Quest?
    /// The journey's own name, or "Free ride".
    var title: String?
    let position: Coordinate?
    let formatter: UnitFormatter

    var body: some View {
        HStack(spacing: 12) {
            DiamondMarker(color: Theme.Colors.sage, size: 18)
            if let objective {
                (Text("QUEST · ").font(Theme.Typography.eyebrow).foregroundStyle(Theme.Colors.sageLight)
                    + Text(objective.title).font(Theme.Typography.text(14, .bold)).foregroundStyle(Theme.Colors.cream))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let position, let target = objective.coordinate {
                    Text(formatter.distance(meters: GeoMath.distance(position, target)))
                        .font(Theme.Typography.text(16, .bold).monospacedDigit()).foregroundStyle(Theme.Colors.cream)
                } else if objective.progress.target > 1 {
                    Text("\(Int(objective.progress.fraction * 100))%").font(Theme.Typography.text(16, .bold).monospacedDigit()).foregroundStyle(Theme.Colors.cream)
                }
            } else {
                Text(quest == nil ? "\(title ?? LoreCopy.free(nil)) · every new road counts" : "All objectives complete · head home")
                    .font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.cream).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Theme.Colors.ink, in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.2), radius: 8, y: 4)
    }
}

/// Objective complete (design 12b): a sage card replaces the instruction for a
/// few seconds with the rising-triplet haptic, then navigation returns.
struct ObjectiveCompleteCard: View {
    let objective: Objective
    let remaining: Int

    var body: some View {
        HStack(spacing: 18) {
            MarkView(.token(.flag, ring: .sage)).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Objective complete", color: Theme.Colors.cream)
                Text(objective.title).font(Theme.Typography.voice(24, relativeTo: .title)).foregroundStyle(Theme.Colors.cream).lineLimit(2)
                Text(remaining == 0 ? "Quest complete · head home" : "\(remaining) objective\(remaining == 1 ? "" : "s") left")
                    .font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.cream)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .background(Theme.Colors.sage, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 6)
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}

/// Off route (design 4c): the card changes voice, not colour alone. No dialog.
///
/// It says what is being done about it and, always, the way back: which way and
/// how far to the nearest of the route, which the map draws as a dashed line. A
/// new route that cannot be fetched is said plainly, with a button to try again.
struct OffRouteCard: View {
    let rerouting: Bool
    let rejoin: RejoinGuide?
    var failure: String?
    let formatter: UnitFormatter
    var onReroute: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(Theme.Colors.terracottaLight)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Off route", color: Theme.Colors.terracottaLight)
                Text(headline)
                    .font(Theme.Typography.text(26, .bold)).foregroundStyle(Theme.Colors.cream).lineLimit(1).minimumScaleFactor(0.6)
                detail.font(Theme.Typography.text(15)).lineLimit(2).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if rerouting {
                ProgressView().tint(Theme.Colors.cream)
            } else {
                Button(action: onReroute) {
                    VStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17, weight: .bold))
                        Text("Reroute").font(Theme.Typography.text(11, .semibold, relativeTo: .caption2))
                    }
                    .foregroundStyle(Theme.Colors.ink)
                    .frame(width: 62, height: 56)
                    .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Reroute now")
                .accessibilityIdentifier("offRoute.reroute")
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offRouteCard")
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    private var headline: String {
        if rerouting { return "Finding a new route…" }
        if let rejoin { return "Head \(rejoin.compass)" }
        return "Finding the route…"
    }

    private var detail: Text {
        let way: Text = {
            guard let rejoin else { return Text("The way back is on the map").foregroundStyle(Theme.Colors.line) }
            return Text(formatter.distance(meters: rejoin.distanceMeters)).font(Theme.Typography.text(15, .bold)).foregroundStyle(Theme.Colors.cream)
                + Text(rerouting ? " \(rejoin.compass) to the old one" : " to the route · dashed on the map").foregroundStyle(Theme.Colors.line)
        }()
        guard let failure, !rerouting else { return way }
        return Text("\(failure) · ").foregroundStyle(Theme.Colors.terracottaLight) + way
    }
}
