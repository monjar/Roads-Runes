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
///
/// Ink map conventions (design turn 2): unexplored ground is cream with roads
/// ghosting through; explored cells are outlined with a dashed ink line; quest
/// waypoints are diamonds, mysteries are dashed "?" circles, the rider is a
/// sage circle; the selected route is terracotta with a white casing.
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
        view.backgroundColor = UIColor(hex: 0xEBDDC5)
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
                guard cell.polygon.count >= 3, cell.state != .visited, cell.state != .explored else { return nil }
                var coords = cell.polygon.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let feature = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
                feature.attributes = ["state": cell.state.rawValue]
                return feature
            }
            let exploredOutline: [MLNPolygonFeature] = parent.cells.compactMap { cell in
                guard cell.state == .explored || cell.state == .visited, cell.polygon.count >= 3 else { return nil }
                var coords = cell.polygon.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let feature = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
                feature.attributes = ["state": cell.state.rawValue]
                return feature
            }
            let source = ensureSource(style, id: "rr-fog")
            source.shape = MLNShapeCollectionFeature(shapes: features)
            if style.layer(withIdentifier: "rr-fog-fill") == nil {
                // Unexplored ground is cream; discovered cells let the map show through a little more.
                let fill = MLNFillStyleLayer(identifier: "rr-fog-fill", source: source)
                fill.fillColor = NSExpression(format: "TERNARY(state == 'DISCOVERED', %@, %@)", UIColor(hex: 0xF5EAD8, alpha: 0.62), UIColor(hex: 0xF5EAD8, alpha: 0.93))
                fill.fillOutlineColor = NSExpression(forConstantValue: UIColor(hex: 0xA19786, alpha: 0.18))
                style.addLayer(fill)
            }
            let outlineSource = ensureSource(style, id: "rr-explored")
            outlineSource.shape = MLNShapeCollectionFeature(shapes: exploredOutline)
            if style.layer(withIdentifier: "rr-explored-line") == nil {
                let line = MLNLineStyleLayer(identifier: "rr-explored-line", source: outlineSource)
                line.lineColor = NSExpression(format: "TERNARY(state == 'EXPLORED', %@, %@)", UIColor(hex: 0x645C50, alpha: 0.7), UIColor(hex: 0x645C50, alpha: 0.35))
                line.lineWidth = NSExpression(forConstantValue: 1.2)
                line.lineDashPattern = NSExpression(forConstantValue: [4, 3])
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
                let glow = MLNLineStyleLayer(identifier: "rr-route-glow", source: source)
                glow.lineColor = NSExpression(forConstantValue: UIColor(hex: 0xC67139, alpha: 0.16))
                glow.lineWidth = NSExpression(forConstantValue: 18)
                glow.lineCap = NSExpression(forConstantValue: "round")
                glow.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(glow)
                let casing = MLNLineStyleLayer(identifier: "rr-route-casing", source: source)
                casing.lineColor = NSExpression(forConstantValue: UIColor.white)
                casing.lineWidth = NSExpression(forConstantValue: 9)
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(casing)
                let line = MLNLineStyleLayer(identifier: "rr-route-line", source: source)
                line.lineColor = NSExpression(forConstantValue: UIColor(hex: 0xC67139))
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
            if annotation is MLNUserLocation {
                return RiderLocationView()
            }
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

/// Shape carries meaning before colour: quests and objectives are diamonds,
/// mysteries are dashed "?" circles, stops are small ink dots.
final class MarkerAnnotationView: MLNAnnotationView {
    init(reuseIdentifier: String, kind: MapMarker.Kind) {
        super.init(reuseIdentifier: reuseIdentifier)
        switch kind {
        case .quest, .questActive, .objective, .objectiveDone:
            let size: CGFloat = 30
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            let diamond = UIView(frame: CGRect(x: 5, y: 5, width: 20, height: 20))
            diamond.backgroundColor = Self.color(for: kind)
            diamond.layer.cornerRadius = 5
            diamond.layer.borderWidth = 2.5
            diamond.layer.borderColor = UIColor.white.cgColor
            diamond.transform = CGAffineTransform(rotationAngle: .pi / 4)
            addSubview(diamond)
            if kind == .objectiveDone {
                let check = UILabel(frame: bounds)
                check.text = "✓"
                check.font = .systemFont(ofSize: 13, weight: .heavy)
                check.textColor = .white
                check.textAlignment = .center
                addSubview(check)
            }
        case .discovery:
            let size: CGFloat = 26
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            let ring = CAShapeLayer()
            ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
            ring.fillColor = UIColor(hex: 0xF5EAD8, alpha: 0.92).cgColor
            ring.strokeColor = UIColor(hex: 0x82796A).cgColor
            ring.lineWidth = 2
            ring.lineDashPattern = [3, 2]
            layer.addSublayer(ring)
            let label = UILabel(frame: bounds)
            label.text = "?"
            label.font = .systemFont(ofSize: 14, weight: .bold)
            label.textColor = UIColor(hex: 0x645C50)
            label.textAlignment = .center
            addSubview(label)
        case .poi:
            let size: CGFloat = 16
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            layer.cornerRadius = size / 2
            layer.borderWidth = 2.5
            layer.borderColor = UIColor.white.cgColor
            backgroundColor = UIColor(hex: 0x201E1D)
        }
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 4
    }

    required init?(coder: NSCoder) { nil }

    private static func color(for kind: MapMarker.Kind) -> UIColor {
        switch kind {
        case .quest: return UIColor(hex: 0x7A8A5E)
        case .questActive: return UIColor(hex: 0xC67139)
        case .objective: return UIColor(hex: 0xC67139)
        case .objectiveDone: return UIColor(hex: 0x56633F)
        case .discovery: return UIColor(hex: 0x82796A)
        case .poi: return UIColor(hex: 0x201E1D)
        }
    }
}

/// "You are here": a sage circle with a white ring and a soft halo.
final class RiderLocationView: MLNUserLocationAnnotationView {
    private let halo = CALayer()
    private let dot = CALayer()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        halo.frame = bounds
        halo.cornerRadius = 22
        halo.backgroundColor = UIColor(hex: 0x7A8A5E, alpha: 0.25).cgColor
        dot.frame = CGRect(x: 11, y: 11, width: 22, height: 22)
        dot.cornerRadius = 11
        dot.backgroundColor = UIColor(hex: 0x7A8A5E).cgColor
        dot.borderColor = UIColor.white.cgColor
        dot.borderWidth = 4
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.3
        dot.shadowOffset = CGSize(width: 0, height: 3)
        dot.shadowRadius = 5
        layer.addSublayer(halo)
        layer.addSublayer(dot)
    }

    required init?(coder: NSCoder) { nil }

    override func update() {
        // Static rendering; the map moves under the rider.
    }
}
