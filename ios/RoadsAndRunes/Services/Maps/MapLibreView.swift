import CoreLocation
import MapLibre
import RoadsAndRunesCore
import SwiftUI

struct MapMarker: Identifiable, Hashable {
    enum Kind: String { case quest, questActive, objective, objectiveDone, discovery, poi }
    let id: String
    let coordinate: Coordinate
    let kind: Kind
    let title: String
}

/// MapLibre wrapper: fog-of-war polygons, route line, markers, user location.
/// Layers are (re)built from SwiftUI state; heavy work stays in the coordinator.
struct MapLibreView: UIViewRepresentable {
    var styleURL: URL
    var center: Coordinate?
    var zoom: Double = 13
    var cells: [CellRender] = []
    var route: [Coordinate] = []
    var markers: [MapMarker] = []
    var followsUser = false
    var navigationMode = false
    var onRegionChanged: ((Coordinate, Double) -> Void)?
    var onMarkerTap: ((MapMarker) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.logoView.isHidden = true
        view.attributionButton.alpha = 0.5
        view.showsUserLocation = true
        view.compassView.isHidden = navigationMode
        if let center {
            view.setCenter(CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude), zoomLevel: zoom, animated: false)
        }
        if followsUser {
            view.userTrackingMode = navigationMode ? .followWithCourse : .follow
        }
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if view.styleURL != styleURL {
            view.styleURL = styleURL
        }
        if followsUser {
            let mode: MLNUserTrackingMode = navigationMode ? .followWithCourse : .follow
            if view.userTrackingMode != mode { view.setUserTrackingMode(mode, animated: true) }
        } else if let center, !context.coordinator.userMovedMap {
            let target = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
            if abs(view.centerCoordinate.latitude - target.latitude) > 0.0005 || abs(view.centerCoordinate.longitude - target.longitude) > 0.0005 {
                view.setCenter(target, zoomLevel: zoom, animated: true)
            }
        }
        context.coordinator.apply(to: view)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapLibreView
        var userMovedMap = false
        private var styleLoaded = false
        private var annotations: [String: MLNPointAnnotation] = [:]
        private var lastCellsHash = 0
        private var lastRouteCount = -1

        init(_ parent: MapLibreView) { self.parent = parent }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            lastCellsHash = 0
            lastRouteCount = -1
            apply(to: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            if mapView.userTrackingMode == .none { userMovedMap = true }
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            parent.onRegionChanged?(center, mapView.zoomLevel)
        }

        func apply(to mapView: MLNMapView) {
            guard styleLoaded, let style = mapView.style else { return }
            applyFog(style)
            applyRoute(style)
            applyMarkers(mapView)
        }

        // MARK: Fog of war (spec §14)

        private func applyFog(_ style: MLNStyle) {
            let hash = parent.cells.reduce(0) { $0 &+ $1.h3.hashValue &+ $1.state.rawValue.hashValue }
            guard hash != lastCellsHash else { return }
            lastCellsHash = hash
            let features: [MLNPolygonFeature] = parent.cells.compactMap { cell in
                guard cell.polygon.count >= 3, cell.state != .visited else { return nil }
                var coords = cell.polygon.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let feature = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
                feature.attributes = ["state": cell.state.rawValue]
                return feature
            }
            let exploredOutline: [MLNPolygonFeature] = parent.cells.compactMap { cell in
                guard cell.state == .explored, cell.polygon.count >= 3 else { return nil }
                var coords = cell.polygon.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                return MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
            }
            let source = ensureSource(style, id: "rr-fog")
            source.shape = MLNShapeCollectionFeature(shapes: features)
            if style.layer(withIdentifier: "rr-fog-fill") == nil {
                let fill = MLNFillStyleLayer(identifier: "rr-fog-fill", source: source)
                fill.fillColor = NSExpression(format: "TERNARY(state == 'DISCOVERED', %@, %@)", UIColor(white: 0.08, alpha: 0.30), UIColor(white: 0.08, alpha: 0.58))
                fill.fillOutlineColor = NSExpression(forConstantValue: UIColor(white: 0.97, alpha: 0.15))
                style.addLayer(fill)
            }
            let outlineSource = ensureSource(style, id: "rr-explored")
            outlineSource.shape = MLNShapeCollectionFeature(shapes: exploredOutline)
            if style.layer(withIdentifier: "rr-explored-line") == nil {
                let line = MLNLineStyleLayer(identifier: "rr-explored-line", source: outlineSource)
                line.lineColor = NSExpression(forConstantValue: UIColor(red: 0.24, green: 0.44, blue: 0.30, alpha: 0.45))
                line.lineWidth = NSExpression(forConstantValue: 1)
                style.addLayer(line)
            }
        }

        // MARK: Route line

        private func applyRoute(_ style: MLNStyle) {
            guard parent.route.count != lastRouteCount else { return }
            lastRouteCount = parent.route.count
            let source = ensureSource(style, id: "rr-route")
            if parent.route.count >= 2 {
                var coords = parent.route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                source.shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            } else {
                source.shape = nil
            }
            if style.layer(withIdentifier: "rr-route-line") == nil {
                let casing = MLNLineStyleLayer(identifier: "rr-route-casing", source: source)
                casing.lineColor = NSExpression(forConstantValue: UIColor.white)
                casing.lineWidth = NSExpression(forConstantValue: 8)
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(casing)
                let line = MLNLineStyleLayer(identifier: "rr-route-line", source: source)
                line.lineColor = NSExpression(forConstantValue: UIColor(red: 0.80, green: 0.55, blue: 0.19, alpha: 0.95))
                line.lineWidth = NSExpression(forConstantValue: 5)
                line.lineCap = NSExpression(forConstantValue: "round")
                line.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(line)
            }
        }

        private func ensureSource(_ style: MLNStyle, id: String) -> MLNShapeSource {
            if let existing = style.source(withIdentifier: id) as? MLNShapeSource { return existing }
            let source = MLNShapeSource(identifier: id, shape: nil, options: nil)
            style.addSource(source)
            return source
        }

        // MARK: Markers

        private func applyMarkers(_ mapView: MLNMapView) {
            let wanted = Dictionary(uniqueKeysWithValues: parent.markers.map { ($0.id, $0) })
            for (id, annotation) in annotations where wanted[id] == nil {
                mapView.removeAnnotation(annotation)
                annotations[id] = nil
            }
            for marker in parent.markers where annotations[marker.id] == nil {
                let annotation = MLNPointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
                annotation.title = marker.title
                annotation.subtitle = marker.kind.rawValue
                mapView.addAnnotation(annotation)
                annotations[marker.id] = annotation
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let point = annotation as? MLNPointAnnotation, let kindRaw = point.subtitle, let kind = MapMarker.Kind(rawValue: kindRaw) else { return nil }
            let identifier = "marker-\(kindRaw)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MarkerAnnotationView(reuseIdentifier: identifier, kind: kind)
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let point = annotation as? MLNPointAnnotation,
                  let entry = annotations.first(where: { $0.value === point }),
                  let marker = parent.markers.first(where: { $0.id == entry.key }) else { return }
            parent.onMarkerTap?(marker)
            mapView.deselectAnnotation(annotation, animated: false)
        }
    }
}

final class MarkerAnnotationView: MLNAnnotationView {
    init(reuseIdentifier: String, kind: MapMarker.Kind) {
        super.init(reuseIdentifier: reuseIdentifier)
        let size: CGFloat = kind == .discovery || kind == .poi ? 14 : 26
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        backgroundColor = Self.color(for: kind)
        centerOffset = CGVector(dx: 0, dy: -size / 2)
    }

    required init?(coder: NSCoder) { nil }

    private static func color(for kind: MapMarker.Kind) -> UIColor {
        switch kind {
        case .quest: return UIColor(red: 0.80, green: 0.55, blue: 0.19, alpha: 1)
        case .questActive: return UIColor(red: 0.76, green: 0.29, blue: 0.20, alpha: 1)
        case .objective: return UIColor(red: 1.0, green: 0.78, blue: 0.20, alpha: 1)
        case .objectiveDone: return UIColor(red: 0.24, green: 0.44, blue: 0.30, alpha: 1)
        case .discovery, .poi: return UIColor(red: 0.22, green: 0.47, blue: 0.62, alpha: 1)
        }
    }
}
