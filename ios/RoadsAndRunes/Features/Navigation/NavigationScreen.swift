import RoadsAndRunesCore
import SwiftUI

/// Full-screen navigation (spec §33): next turn first, map, objective, then
/// secondary metrics. No XP animation while moving.
struct NavigationScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var confirmingEnd = false

    private var recorder: RideRecorder { container.rideRecorder }
    private var formatter: UnitFormatter { UnitFormatter(units: container.session.units) }

    var body: some View {
        VStack(spacing: 0) {
            TurnCard(progress: recorder.progress, route: recorder.package?.route, state: recorder.state, formatter: formatter)
            ZStack(alignment: .top) {
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
                if recorder.state == .offRoute || recorder.state == .rerouting {
                    Text(recorder.state == .rerouting ? "Finding a way back…" : "Off route · heading back to the line")
                        .font(Theme.Typography.caption.weight(.bold))
                        .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
                        .background(Theme.Colors.navWarning, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, Theme.Spacing.sm)
                }
                if let objective = recorder.recentObjectiveCompletion {
                    ObjectiveCompleteToast(objective: objective).padding(.top, 48)
                }
            }
            VStack(spacing: Theme.Spacing.sm) {
                ObjectiveBanner(objective: recorder.currentObjective, quest: recorder.quest, position: recorder.lastFix?.coordinate, formatter: formatter)
                HStack {
                    NavMetric(title: formatter.distanceUnitLabel, value: formatter.distanceValue(meters: recorder.stats.distanceMeters).formatted(.number.precision(.fractionLength(1))))
                    NavMetric(title: "time", value: formatter.duration(seconds: recorder.stats.elapsedSeconds))
                    NavMetric(title: formatter.speedUnitLabel, value: String(Int(formatter.speedValue(metersPerSecond: recorder.stats.currentSpeedMps).rounded())))
                    NavMetric(title: "climb", value: formatter.elevation(meters: recorder.stats.elevationGainMeters))
                    NavMetric(title: "bpm", value: recorder.stats.lastHeartRateBpm.map(String.init) ?? "--")
                }
                HStack(spacing: Theme.Spacing.sm) {
                    Button(recorder.state == .paused ? "Resume" : "Pause") {
                        if recorder.state == .paused { recorder.resume() } else { recorder.pause() }
                    }
                    .buttonStyle(.borderedProminent).tint(Color(white: 0.2)).controlSize(.large).frame(maxWidth: .infinity)
                    Button("End ride") { confirmingEnd = true }
                        .buttonStyle(.borderedProminent).tint(Theme.Colors.ember).controlSize(.large).frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.Spacing.md)
            .background(Color(white: 0.07))
        }
        .background(Theme.Colors.navBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .confirmationDialog("End this ride?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("Finish and save", role: .none) { Task { await recorder.finish() } }
            Button("Discard ride", role: .destructive) { recorder.discard() }
            Button("Keep riding", role: .cancel) {}
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var markers: [MapMarker] {
        var out: [MapMarker] = []
        if let quest = recorder.quest {
            for objective in quest.objectives {
                if let coordinate = objective.coordinate {
                    out.append(MapMarker(id: objective.id.uuidString, coordinate: coordinate, kind: objective.status == .completed ? .objectiveDone : .objective, title: objective.title))
                }
            }
        }
        for poi in recorder.package?.pois.prefix(6) ?? [] {
            out.append(MapMarker(id: poi.discoveryId.uuidString, coordinate: poi.coordinate, kind: .poi, title: poi.name))
        }
        return out
    }
}

struct TurnCard: View {
    let progress: ProgressUpdate?
    let route: RouteOption?
    let state: NavigationState
    let formatter: UnitFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let instruction = progress?.nextInstruction {
                HStack(alignment: .center, spacing: Theme.Spacing.md) {
                    TurnArrowView(sign: instruction.sign)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(formatter.distance(meters: progress?.distanceToNextInstruction ?? instruction.distanceMeters))
                            .font(Theme.Typography.navDistance).foregroundStyle(Theme.Colors.navForeground).minimumScaleFactor(0.5).lineLimit(1)
                        Text(TurnArrowView.word(for: instruction.sign)).font(.headline.weight(.bold)).tracking(2).foregroundStyle(Theme.Colors.navAccent)
                    }
                }
                Text(instruction.streetName.isEmpty ? instruction.text : instruction.streetName)
                    .font(Theme.Typography.navStreet).foregroundStyle(Theme.Colors.navForeground).lineLimit(2).minimumScaleFactor(0.7)
                if let next = route?.instructions.first(where: { $0.index > instruction.index }) {
                    Text("then \(next.text)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.navForeground.opacity(0.6)).lineLimit(1)
                }
            } else {
                Text(state == .paused ? "Paused" : "Follow the route").font(Theme.Typography.navStreet).foregroundStyle(Theme.Colors.navForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.navBackground)
    }
}

struct TurnArrowView: View {
    let sign: InstructionSign

    var body: some View {
        Image(systemName: Self.symbol(for: sign)).font(.system(size: 72, weight: .bold)).foregroundStyle(Theme.Colors.navAccent).frame(width: 96)
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
}

struct ObjectiveBanner: View {
    let objective: Objective?
    let quest: Quest?
    let position: Coordinate?
    let formatter: UnitFormatter

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "scope").foregroundStyle(Theme.Colors.navAccent)
            if let objective {
                Text(objective.title).font(Theme.Typography.body.weight(.semibold)).foregroundStyle(Theme.Colors.navForeground).lineLimit(1)
                if let quest { Text("· \(quest.title)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.navForeground.opacity(0.6)).lineLimit(1) }
                Spacer()
                if let position, let target = objective.coordinate {
                    Text(formatter.distance(meters: GeoMath.distance(position, target))).font(Theme.Typography.body.weight(.bold).monospacedDigit()).foregroundStyle(Theme.Colors.navForeground)
                }
            } else {
                Text(quest == nil ? "Free ride" : "All objectives complete").font(Theme.Typography.body).foregroundStyle(Theme.Colors.navForeground)
                Spacer()
            }
        }
    }
}

struct ObjectiveCompleteToast: View {
    let objective: Objective

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Colors.moss)
            VStack(alignment: .leading, spacing: 0) {
                Text("Objective complete").font(Theme.Typography.caption.weight(.bold))
                Text(objective.title).font(Theme.Typography.caption).lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Spacing.md).padding(.vertical, Theme.Spacing.sm)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
