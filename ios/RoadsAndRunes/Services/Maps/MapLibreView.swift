import CoreLocation
import MapLibre
import RoadsAndRunesCore
import SwiftUI

struct MapMarker: Identifiable, Hashable {
    enum Kind: String {
        case quest, questActive, objective, objectiveDone, discovery, poi, place, result
        /// A stop on the route — a café, a pub, a landmark — and the one being read.
        case stop, stopActive
        /// The world's objects: a chest to pass, a piece to gather, a monster to beat, the day's bounty.
        case chest, collectable, monster, bounty
    }

    let id: String
    let coordinate: Coordinate
    let kind: Kind
    let title: String
    /// SF Symbol drawn inside the marker, so a stop looks like what it is.
    var symbol: String?
}

/// A one-shot camera move. A new value (new `id`) moves the map once; the rider
/// is free to pan afterwards. `fit` wins over `center` when it has 2+ points.
struct MapCamera: Equatable {
    let id = UUID()
    var center: Coordinate?
    var zoom: Double?
    var fit: [Coordinate] = []
    var padding = UIEdgeInsets(top: 80, left: 40, bottom: 80, right: 40)
}

/// A named place from the base map's POI layer under the rider's finger.
struct MapFeature: Hashable {
    let name: String
    let kind: String?
    let subkind: String?
    let coordinate: Coordinate
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
    /// False for a route preview inside a scroll view: markers stay tappable, but
    /// the map does not steal the drag that scrolls the page.
    var interactive = true
    var onRegionChanged: ((Coordinate, Double) -> Void)?
    var onMarkerTap: ((MapMarker) -> Void)?
    var camera: MapCamera?
    /// Tap on the map away from markers, with the base-map POI there if any.
    var onMapTap: ((Coordinate, MapFeature?) -> Void)?
    var onLongPress: ((Coordinate) -> Void)?
    var onVisibleRegionChanged: ((BoundingBox) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.logoView.isHidden = true
        view.attributionButton.alpha = 0.5
        view.showsUserLocation = true
        // Asks the location manager for heading, so the rider's marker can point
        // somewhere while they are stopped (MLNUserLocation.heading is nil without it).
        view.showsUserHeadingIndicator = true
        view.compassView.isHidden = navigationMode
        view.applyInteraction(interactive)
        view.backgroundColor = UIColor(hex: 0xEBDDC5)
        if let center {
            view.setCenter(CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude), zoomLevel: zoom, animated: false)
        }
        if followsUser {
            view.userTrackingMode = navigationMode ? .followWithCourse : .follow
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        for recognizer in view.gestureRecognizers ?? [] where (recognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 {
            tap.require(toFail: recognizer)
        }
        view.addGestureRecognizer(tap)
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        press.delegate = context.coordinator
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.parent = self
        view.applyInteraction(interactive)
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

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: MapLibreView
        var userMovedMap = false
        private var lastCameraId: UUID?
        private var poiLayerIds: Set<String> = []
        private var styleLoaded = false
        private var markers: [String: (marker: MapMarker, annotation: MLNPointAnnotation)] = [:]
        private var lastCellsHash = 0
        private var lastRouteHash: Int?
        private var appliedFollowZoom = false

        init(_ parent: MapLibreView) { self.parent = parent }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            poiLayerIds = Set(style.layers.compactMap { layer in
                guard let symbols = layer as? MLNSymbolStyleLayer, symbols.sourceLayerIdentifier == "poi" else { return nil }
                return symbols.identifier
            })
            lastCellsHash = 0
            lastRouteHash = nil
            apply(to: mapView)
            reportVisibleRegion(mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            if mapView.userTrackingMode == .none { userMovedMap = true }
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            parent.onRegionChanged?(center, mapView.zoomLevel)
            reportVisibleRegion(mapView)
        }

        private func reportVisibleRegion(_ mapView: MLNMapView) {
            let bounds = mapView.visibleCoordinateBounds
            parent.onVisibleRegionChanged?(BoundingBox(minLat: bounds.sw.latitude, minLon: bounds.sw.longitude, maxLat: bounds.ne.latitude, maxLon: bounds.ne.longitude))
        }

        func apply(to mapView: MLNMapView) {
            guard styleLoaded, let style = mapView.style else { return }
            applyFog(style)
            applyRoute(style)
            applyMarkers(mapView)
            applyCamera(mapView)
            applyFollowZoom(mapView)
        }

        // MARK: Camera

        private func applyCamera(_ mapView: MLNMapView) {
            guard let camera = parent.camera, camera.id != lastCameraId, !mapView.bounds.isEmpty else { return }
            lastCameraId = camera.id
            userMovedMap = true  // the command owns the camera now; don't snap back to `center`
            if camera.fit.count >= 2 {
                var coords = camera.fit.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let shape = MLNPolyline(coordinates: &coords, count: UInt(coords.count))
                mapView.setCamera(mapView.cameraThatFitsShape(shape, direction: 0, edgePadding: camera.padding), animated: true)
            } else if let center = camera.center {
                let target = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
                mapView.setCenter(target, zoomLevel: camera.zoom ?? max(mapView.zoomLevel, 15), animated: true)
            }
        }

        /// A ride that starts before the first fix arrives opens on a map of the whole
        /// world: user tracking keeps the rider centred but never zooms in, so the
        /// requested zoom is applied as soon as there is a location to apply it to.
        private func applyFollowZoom(_ mapView: MLNMapView) {
            guard parent.followsUser else {
                appliedFollowZoom = false
                return
            }
            guard !appliedFollowZoom, !mapView.bounds.isEmpty, mapView.userLocation?.location != nil else { return }
            appliedFollowZoom = true
            if abs(mapView.zoomLevel - parent.zoom) > 0.25 { mapView.setZoomLevel(parent.zoom, animated: true) }
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
            let hash = routeHash()
            guard hash != lastRouteHash else { return }
            lastRouteHash = hash
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

        /// Two alternatives often have the same number of points, and comparing counts
        /// left the previous route drawn under the one the rider had just picked.
        private func routeHash() -> Int {
            var hasher = Hasher()
            hasher.combine(parent.route.count)
            hasher.combine(parent.route.first)
            hasher.combine(parent.route.last)
            if parent.route.count > 8 {
                for index in stride(from: 0, to: parent.route.count, by: parent.route.count / 8) {
                    hasher.combine(parent.route[index])
                }
            }
            return hasher.finalize()
        }

        private func ensureSource(_ style: MLNStyle, id: String) -> MLNShapeSource {
            if let existing = style.source(withIdentifier: id) as? MLNShapeSource { return existing }
            let source = MLNShapeSource(identifier: id, shape: nil, options: nil)
            style.addSource(source)
            return source
        }

        // MARK: Markers

        private func applyMarkers(_ mapView: MLNMapView) {
            // Keep the first of any duplicate ids rather than trapping on them.
            let wanted = Dictionary(parent.markers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Comparing the whole marker, not just its id: a stop that becomes the
            // selected one changes how it is drawn under the same id.
            for (id, entry) in markers where wanted[id] != entry.marker {
                mapView.removeAnnotation(entry.annotation)
                markers[id] = nil
            }
            for (id, marker) in wanted where markers[id] == nil {
                let annotation = MLNPointAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: marker.coordinate.latitude, longitude: marker.coordinate.longitude)
                annotation.title = marker.title
                annotation.subtitle = marker.kind.rawValue
                // Recorded before it is added: the map asks for the annotation's view
                // inside `addAnnotation`, and an unknown marker gets a default red pin.
                markers[id] = (marker, annotation)
                mapView.addAnnotation(annotation)
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is MLNUserLocation {
                return RiderLocationView()
            }
            guard let marker = marker(for: annotation) else { return nil }
            let identifier = "marker-\(marker.kind.rawValue)-\(marker.symbol ?? "plain")"
            return mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MarkerAnnotationView(reuseIdentifier: identifier, kind: marker.kind, symbol: marker.symbol)
        }

        private func marker(for annotation: MLNAnnotation) -> MapMarker? {
            guard let point = annotation as? MLNPointAnnotation else { return nil }
            return markers.values.first { $0.annotation === point }?.marker
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let marker = marker(for: annotation) else { return }
            parent.onMarkerTap?(marker)
            mapView.deselectAnnotation(annotation, animated: false)
        }

        // MARK: Taps (places, dropped pins)

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView = gesture.view as? MLNMapView, let onMapTap = parent.onMapTap else { return }
            let point = gesture.location(in: mapView)
            // A tap on a marker is handled by didSelect; don't also treat it as a map tap.
            for entry in markers.values {
                let at = mapView.convert(entry.annotation.coordinate, toPointTo: mapView)
                if hypot(at.x - point.x, at.y - point.y) < 22 { return }
            }
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            onMapTap(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude), poi(at: point, in: mapView))
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = gesture.view as? MLNMapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            parent.onLongPress?(Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }

        /// The named POI label nearest the finger, from the style's "poi" source layer.
        private func poi(at point: CGPoint, in mapView: MLNMapView) -> MapFeature? {
            guard !poiLayerIds.isEmpty else { return nil }
            let area = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
            let nearest = mapView.visibleFeatures(in: area, styleLayerIdentifiers: poiLayerIds)
                .compactMap { feature -> (MLNFeature, String, CGFloat)? in
                    guard let name = feature.attribute(forKey: "name") as? String, !name.isEmpty else { return nil }
                    let at = mapView.convert(feature.coordinate, toPointTo: mapView)
                    return (feature, name, hypot(at.x - point.x, at.y - point.y))
                }
                .min { $0.2 < $1.2 }
            guard let (feature, name, _) = nearest else { return nil }
            return MapFeature(
                name: name,
                kind: feature.attribute(forKey: "class") as? String,
                subkind: feature.attribute(forKey: "subclass") as? String,
                coordinate: Coordinate(latitude: feature.coordinate.latitude, longitude: feature.coordinate.longitude)
            )
        }
    }
}

/// Shape carries meaning before colour: quests and objectives are diamonds,
/// mysteries are dashed "?" circles, stops are small ink dots.
final class MarkerAnnotationView: MLNAnnotationView {
    init(reuseIdentifier: String, kind: MapMarker.Kind, symbol: String? = nil) {
        super.init(reuseIdentifier: reuseIdentifier)
        switch kind {
        case .stop, .stopActive:
            // A stop on the route reads as what it is — a cup, a mug, a column —
            // and grows while the rider has it open.
            let size: CGFloat = kind == .stopActive ? 40 : 30
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            layer.cornerRadius = size / 2
            layer.borderWidth = kind == .stopActive ? 3.5 : 2.5
            layer.borderColor = UIColor.white.cgColor
            backgroundColor = Self.color(for: kind)
            if let symbol,
               let glyph = UIImage(
                   systemName: symbol,
                   withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.44, weight: .bold)
               ) {
                let image = UIImageView(image: glyph.withTintColor(.white, renderingMode: .alwaysOriginal))
                image.frame = bounds
                image.contentMode = .center
                addSubview(image)
            }
        case .chest, .collectable, .monster, .bounty:
            // The world's objects read as what they are: a box, a spark, a flame; the
            // bounty wears a gold ring.
            let size: CGFloat = kind == .collectable ? 26 : 34
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            layer.cornerRadius = size / 2
            layer.borderWidth = kind == .bounty ? 3.5 : 2.5
            layer.borderColor = kind == .bounty ? UIColor(red: 0.85, green: 0.65, blue: 0.13, alpha: 1).cgColor : UIColor.white.cgColor
            backgroundColor = Self.color(for: kind)
            let name: String = {
                switch kind {
                case .chest: return "shippingbox.fill"
                case .collectable: return "sparkles"
                default: return "flame.fill"
                }
            }()
            if let glyph = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.46, weight: .bold)) {
                let image = UIImageView(image: glyph.withTintColor(.white, renderingMode: .alwaysOriginal))
                image.frame = bounds
                image.contentMode = .center
                addSubview(image)
            }
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
        case .place:
            // The selected place: a terracotta teardrop whose tip sits on the coordinate.
            frame = CGRect(x: 0, y: 0, width: 30, height: 40)
            let pin = CAShapeLayer()
            let path = UIBezierPath(arcCenter: CGPoint(x: 15, y: 15), radius: 13, startAngle: .pi * 0.8, endAngle: .pi * 0.2, clockwise: true)
            path.addLine(to: CGPoint(x: 15, y: 38))
            path.close()
            pin.path = path.cgPath
            pin.fillColor = Self.color(for: kind).cgColor
            pin.strokeColor = UIColor.white.cgColor
            pin.lineWidth = 2.5
            layer.addSublayer(pin)
            let dot = CALayer()
            dot.frame = CGRect(x: 10, y: 10, width: 10, height: 10)
            dot.cornerRadius = 5
            dot.backgroundColor = UIColor.white.cgColor
            layer.addSublayer(dot)
            centerOffset = CGVector(dx: 0, dy: -18)
        case .result:
            let size: CGFloat = 18
            frame = CGRect(x: 0, y: 0, width: size, height: size)
            layer.cornerRadius = size / 2
            layer.borderWidth = 3
            layer.borderColor = UIColor.white.cgColor
            backgroundColor = Self.color(for: kind)
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
        case .stop: return UIColor(hex: 0xC67139)
        case .stopActive: return UIColor(hex: 0x8C491A)
        case .place, .result: return UIColor(hex: 0xC67139)
        case .chest: return UIColor(hex: 0x4A433A)
        case .collectable: return UIColor(hex: 0x56633F)
        case .monster, .bounty: return UIColor(hex: 0x8C491A)
        }
    }
}

/// "You are here": a sage circle with a white ring and a soft halo, with a beak
/// pointing the way the rider is facing — their course while they are moving, the
/// compass while they are stopped, and nothing at all when neither is known.
final class RiderLocationView: MLNUserLocationAnnotationView {
    private let halo = CALayer()
    private let dot = CALayer()
    private let beak = CAShapeLayer()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        halo.frame = bounds.insetBy(dx: 4, dy: 4)
        halo.cornerRadius = 22
        halo.backgroundColor = UIColor(hex: 0x7A8A5E, alpha: 0.25).cgColor
        // Added before the dot so the dot covers its base; rotated about the centre,
        // which is the coordinate itself.
        beak.frame = bounds
        beak.path = Self.beak(in: bounds)
        beak.fillColor = UIColor(hex: 0x7A8A5E).cgColor
        beak.strokeColor = UIColor.white.cgColor
        beak.lineWidth = 2
        beak.lineJoin = .round
        beak.isHidden = true
        dot.frame = CGRect(x: 15, y: 15, width: 22, height: 22)
        dot.cornerRadius = 11
        dot.backgroundColor = UIColor(hex: 0x7A8A5E).cgColor
        dot.borderColor = UIColor.white.cgColor
        dot.borderWidth = 4
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.3
        dot.shadowOffset = CGSize(width: 0, height: 3)
        dot.shadowRadius = 5
        layer.addSublayer(halo)
        layer.addSublayer(beak)
        layer.addSublayer(dot)
    }

    required init?(coder: NSCoder) { nil }

    private static func beak(in bounds: CGRect) -> CGPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: bounds.midX, y: 1))
        path.addLine(to: CGPoint(x: bounds.midX + 9, y: 17))
        path.addLine(to: CGPoint(x: bounds.midX - 9, y: 17))
        path.close()
        return path.cgPath
    }

    override func update() {
        guard let bearing = travelDirection else {
            beak.isHidden = true
            return
        }
        beak.isHidden = false
        // Relative to the map's own rotation: in navigation the map turns with the
        // rider, and the beak must keep pointing up rather than turning twice.
        let radians = (bearing - (mapView?.direction ?? 0)) * .pi / 180
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // no spinning the long way round
        beak.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(radians)))
        CATransaction.commit()
    }

    /// A course needs movement to mean anything; a heading needs the compass. A rider
    /// standing still with neither gets a plain dot instead of a confident lie.
    private var travelDirection: CLLocationDirection? {
        if let location = userLocation?.location, location.course >= 0, location.speed > 0.7 {
            return location.course
        }
        if let heading = userLocation?.heading?.trueHeading, heading >= 0 {
            return heading
        }
        return nil
    }
}

extension MLNMapView {
    /// A preview map inside a scroll view: taps still select markers, but pans,
    /// pinches and rotations belong to the page, not the map.
    func applyInteraction(_ enabled: Bool) {
        guard isScrollEnabled != enabled else { return }
        isScrollEnabled = enabled
        isZoomEnabled = enabled
        isRotateEnabled = enabled
        isPitchEnabled = enabled
    }
}
