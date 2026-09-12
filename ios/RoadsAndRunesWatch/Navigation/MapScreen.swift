import MapKit
import RoadsAndRunesCore
import SwiftUI

/// The ride as a map (design 7a, the page the iPhone has and the Watch did not):
/// the route in terracotta, the stops on it, and the rider in sage, held close
/// enough to see the next junction.
///
/// Everything here comes from the phone — the line with the route summary, the
/// position with each navigation update — so the Watch never runs its own GPS
/// and the two screens can never disagree about where the rider is.
struct MapScreen: View {
    @Environment(RideStore.self) private var store
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var camera: MapCameraPosition = .automatic
    /// Roughly a couple of streets across, like the phone's riding zoom.
    @State private var span: CLLocationDistance = 400

    var body: some View {
        ZStack(alignment: .topLeading) {
            Map(position: $camera, interactionModes: [.zoom, .pan]) {
                if store.routePath.count > 1 {
                    MapPolyline(coordinates: store.routePath)
                        .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                ForEach(store.stops) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate.clLocation) {
                        Circle()
                            .fill(stop.requested ? WatchTheme.accent : WatchTheme.tertiary)
                            .stroke(.white, lineWidth: 1.5)
                            .frame(width: 10, height: 10)
                    }
                    .annotationTitles(.hidden)
                }
                if let here = store.riderCoordinate {
                    Annotation("You", coordinate: here.clLocation) {
                        Circle()
                            .fill(WatchTheme.sage)
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 14, height: 14)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            if store.routePath.isEmpty {
                Text("No route on the watch yet")
                    .font(.system(size: 12))
                    .foregroundStyle(WatchTheme.secondary)
                    .padding(6)
            }
        }
        .onAppear { follow(animated: false) }
        .onChange(of: store.riderCoordinate) { _, _ in follow(animated: !isLuminanceReduced) }
    }

    /// Keep the rider centred. They can pinch and drag; the next fix takes it back,
    /// which is the right trade on a screen with nowhere to put a "recentre" button.
    private func follow(animated: Bool) {
        guard let here = store.riderCoordinate ?? store.routePath.first.map(Coordinate.init(_:)) else { return }
        let region = MKCoordinateRegion(center: here.clLocation, latitudinalMeters: span, longitudinalMeters: span)
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }
}

extension Coordinate {
    var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
