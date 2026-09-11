import RoadsAndRunesCore
import SwiftUI

/// Active navigation (design 4a/12a): instruction card on cream over the map,
/// the quest as a second, quieter ink line, three stats in an ink pill.
/// Objective complete (12b) and off route (4c) replace the instruction card;
/// paused (8d) replaces the stats pill. No XP animation while moving (spec §33).
struct NavigationScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var confirmingEnd = false

    private var recorder: RideRecorder { container.rideRecorder }
    private var formatter: UnitFormatter { UnitFormatter(units: container.session.units) }

    var body: some View {
        ZStack {
            MapLibreView(
                styleURL: Config.mapStyleURL(for: .minimal),
                center: recorder.lastFix?.coordinate ?? recorder.package?.route.path.first,
                zoom: 15.5,
                cells: [],
                route: recorder.package?.route.path ?? [],
                markers: markers,
                followsUser: true,
                navigationMode: true
            )
            .ignoresSafeArea()
            VStack(spacing: 8) {
                topCard
                if recorder.recentObjectiveCompletion != nil, let instruction = recorder.progress?.nextInstruction {
                    MapPill(text: "\(TurnArrowView.phrase(for: instruction.sign)) · \(formatter.distance(meters: recorder.progress?.distanceToNextInstruction ?? instruction.distanceMeters))")
                } else {
                    ObjectiveBanner(objective: recorder.currentObjective, quest: recorder.quest, title: recorder.title, position: recorder.lastFix?.coordinate, formatter: formatter)
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
        .confirmationDialog("End this ride?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End & save") { Task { await recorder.finish() } }
            Button("Discard ride", role: .destructive) { recorder.discard() }
            Button("Keep riding", role: .cancel) {}
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
        } else if recorder.state == .offRoute || recorder.state == .rerouting || recorder.isRerouting {
            OffRouteCard(rerouting: recorder.isRerouting || recorder.state == .rerouting, rejoinMeters: recorder.progress?.crossTrackDistance, formatter: formatter)
        } else {
            TurnCard(progress: recorder.progress, route: recorder.package?.route, state: recorder.state, formatter: formatter)
        }
    }

    private var remainingObjectives: Int {
        guard let quest = recorder.quest else { return 0 }
        return quest.requiredObjectives.filter { !recorder.completedObjectiveIDs.contains($0.id) && $0.status != .completed }.count
    }

    private var statsPill: some View {
        HStack(spacing: 0) {
            NavMetric(title: "\(formatter.distanceUnitLabel) ridden", value: formatter.distanceValue(meters: recorder.stats.distanceMeters).formatted(.number.precision(.fractionLength(1))))
            NavMetric(title: "\(formatter.distanceUnitLabel) new territory", value: formatter.distanceValue(meters: recorder.newTerritoryMeters).formatted(.number.precision(.fractionLength(1))), accent: true, alignment: .center)
                .padding(.horizontal, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.Colors.cream.opacity(0.15)).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.Colors.cream.opacity(0.15)).frame(width: 1) }
            NavMetric(title: "ride time", value: formatter.duration(seconds: recorder.stats.elapsedSeconds), alignment: .trailing)
            Button { recorder.pause() } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.Colors.cream)
                    .frame(width: 48, height: 48)
                    .background(Theme.Colors.inkSoft, in: Circle())
            }
            .buttonStyle(.pressable)
            .padding(.leading, 18)
            .accessibilityLabel("Pause ride")
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 22)
        .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 16, y: 12)
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
                    HStack(spacing: 8) { Image(systemName: "play.fill"); Text("Resume") }
                }
                .buttonStyle(.sage)
                .frame(maxWidth: .infinity)
                Button { confirmingEnd = true } label: {
                    Text("End")
                        .font(Theme.Typography.buttonSmall)
                        .foregroundStyle(Theme.Colors.terracottaLight)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Theme.Colors.inkSoft, in: Capsule())
                }
                .buttonStyle(.pressable)
                .frame(width: 120)
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
        for poi in recorder.package?.pois.prefix(6) ?? [] {
            out.append(MapMarker(id: poi.discoveryId.uuidString, coordinate: poi.coordinate, kind: .poi, title: poi.name))
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
                    Text(state == .paused ? "Paused" : (route == nil ? "Free ride" : "Follow the route")).font(Theme.Typography.text(24, .bold)).foregroundStyle(Theme.Colors.ink)
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

/// The quest as a second, quieter line: diamond, "QUEST · objective", distance.
struct ObjectiveBanner: View {
    let objective: Objective?
    let quest: Quest?
    /// Custom adventure name shown in place of "Free ride".
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
                Text(quest == nil ? "\(title ?? "Free ride") · every new road counts" : "All objectives complete · head home")
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
            ZStack {
                Circle().fill(Theme.Colors.cream)
                Image(systemName: "sparkle").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.Colors.sage)
            }
            .frame(width: 64, height: 64)
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
struct OffRouteCard: View {
    let rerouting: Bool
    let rejoinMeters: Double?
    let formatter: UnitFormatter

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "arrow.triangle.swap")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.Colors.terracottaLight)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Off route", color: Theme.Colors.terracottaLight)
                Text(rerouting ? "Finding a way back…" : "Rejoining route…")
                    .font(Theme.Typography.text(28, .bold)).foregroundStyle(Theme.Colors.cream).lineLimit(1).minimumScaleFactor(0.7)
                if let rejoinMeters {
                    (Text("Keep going · route is ").foregroundStyle(Theme.Colors.line)
                        + Text(formatter.distance(meters: rejoinMeters)).font(Theme.Typography.text(15, .bold)).foregroundStyle(Theme.Colors.cream)
                        + Text(" away").foregroundStyle(Theme.Colors.line))
                        .font(Theme.Typography.text(15))
                } else {
                    Text("Keep going · we will pick the route back up").font(Theme.Typography.text(15)).foregroundStyle(Theme.Colors.line)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(Theme.Colors.ink, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.25), radius: 12, y: 6)
        .onAppear { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }
}
