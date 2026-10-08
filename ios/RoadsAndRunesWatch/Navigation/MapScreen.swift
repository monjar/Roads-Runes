import MapKit
import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// The ride as a map (design 7a, the page the iPhone has and the Watch did not):
/// the route in terracotta, the stops on it, the game near it (creatures, chests,
/// rune stones and objective places, as small marks; 0.7.2), and the rider in
/// sage, held close enough to see the next junction.
///
/// Everything here comes from the phone — the line with the route summary, the
/// position with each navigation update — so the Watch never runs its own GPS
/// and the two screens can never disagree about where the rider is.
///
/// Always-On (0.7.3) keeps the route and the rider, dimmed, with the next turn
/// over the top; the game's marks go, nothing animates, and the map follows the
/// rider only every `alwaysOnFollowEvery`.
struct MapScreen: View {
    @Environment(RideStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var camera: MapCameraPosition = .automatic
    /// Roughly a couple of streets across, like the phone's riding zoom.
    @State private var span: CLLocationDistance = 400
    @State private var lastFollowed: Date = .distantPast

    /// In Always-On the map moves at most this often.
    static let alwaysOnFollowEvery: TimeInterval = 15

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera, interactionModes: [.zoom, .pan]) {
                if store.routePath.count > 1 {
                    MapPolyline(coordinates: store.routePath)
                        .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                if !isLuminanceReduced {
                    marks
                }
                if let here = store.riderCoordinate {
                    Annotation("You", coordinate: here.clLocation) {
                        RiderDot(course: store.riderCourse)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: isLuminanceReduced ? .muted : .automatic, pointsOfInterest: .excludingAll))
            .opacity(isLuminanceReduced ? 0.55 : 1)
            if store.routePath.isEmpty {
                Text("No route on the watch yet")
                    .font(.system(size: 12))
                    .foregroundStyle(WatchTheme.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isLuminanceReduced, let instruction = store.currentInstruction {
                NextTurnBadge(instruction: instruction, distance: store.currentDistanceToInstruction, formatter: store.formatter)
                    .padding(.top, 2)
            }
        }
        .onAppear { follow(animated: false) }
        .onChange(of: store.riderCoordinate) { _, _ in
            if isLuminanceReduced, Date().timeIntervalSince(lastFollowed) < Self.alwaysOnFollowEvery { return }
            follow(animated: !isLuminanceReduced)
        }
        .onChange(of: isLuminanceReduced) { _, reduced in
            if !reduced { follow(animated: false) }
        }
    }

    /// The game near the route and the stops on it: off in Always-On.
    @MapContentBuilder
    private var marks: some MapContent {
        // What is opened or defeated on the way comes off (`RideStore.worldMarks`).
        ForEach(store.worldMarks) { mark in
            Annotation(mark.name, coordinate: mark.coordinate.clLocation) {
                MarkView(WristMarks.mark(mark), palette: .watch)
                    .frame(width: WristMarks.size(mark), height: WristMarks.size(mark))
            }
            .annotationTitles(.hidden)
        }
        ForEach(store.stops) { stop in
            Annotation(stop.name, coordinate: stop.coordinate.clLocation) {
                if let mark = WristMarks.stop(stop) {
                    MarkView(mark, palette: .watch)
                        .frame(width: 16, height: 16)
                } else {
                    Circle()
                        .fill(stop.requested ? WatchTheme.accent : WatchTheme.tertiary)
                        .stroke(.black, lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                }
            }
            .annotationTitles(.hidden)
        }
    }

    /// Keep the rider centred. They can pinch and drag; the next fix takes it back,
    /// which is the right trade on a screen with nowhere to put a "recentre" button.
    private func follow(animated: Bool) {
        guard let here = store.riderCoordinate ?? store.routePath.first.map(Coordinate.init(_:)) else { return }
        lastFollowed = Date()
        let region = MKCoordinateRegion(center: here.clLocation, latitudinalMeters: span, longitudinalMeters: span)
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }
}

/// The next turn over the Always-On map: its arrow and how far, nothing to read.
struct NextTurnBadge: View {
    let instruction: Instruction
    let distance: Double?
    let formatter: UnitFormatter

    var body: some View {
        HStack(spacing: 6) {
            TurnArrow(sign: instruction.sign, size: 22, color: .white.opacity(0.75))
            Text(formatter.distance(meters: distance ?? instruction.distanceMeters))
                .font(.system(size: 20, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.75), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.map.nextTurn")
    }
}

/// The rider on the Watch map: a sage dot with a pointer the way they are
/// heading, as the phone's has. The map is north-up, so the pointer turns by the
/// course itself; before the rider has moved there is no pointer.
struct RiderDot: View {
    let course: Double?

    var body: some View {
        ZStack {
            if let course {
                Pointer()
                    .fill(WatchTheme.sage)
                    .stroke(.black, lineWidth: 1.5)
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(course))
            }
            Circle()
                .fill(WatchTheme.sage)
                .stroke(WatchTheme.cream, lineWidth: 2)
                .frame(width: 14, height: 14)
        }
        .frame(width: 26, height: 26)
        .accessibilityLabel(course.map { "You, heading \(Int($0.rounded())) degrees" } ?? "You")
    }

    /// A short triangle standing on the dot, pointing up (north) before it turns.
    struct Pointer: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.midY - rect.height * 0.08))
            path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.midY - rect.height * 0.08))
            path.closeSubpath()
            return path
        }
    }
}

extension Coordinate {
    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
