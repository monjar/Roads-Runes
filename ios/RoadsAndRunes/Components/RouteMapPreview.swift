import RoadsAndRunesCore
import SwiftUI

/// The chosen route drawn on a map with its stops on it (design 3a), so the cafés
/// and landmarks a rider asked for are something they can see and tap, not a list
/// of names under the numbers.
///
/// The map itself is not interactive: it lives inside a scrolling sheet, where a
/// pan belongs to the page. A tap on a stop is the one gesture it takes.
struct RouteMapPreview: View {
    let route: RouteOption
    var camera: MapCamera?
    var focused: RoutePOI?
    let units: Units
    var height: CGFloat = 200
    var onSelect: (RoutePOI) -> Void
    var onClearFocus: () -> Void = {}

    var body: some View {
        MapLibreView(
            styleURL: Config.mapStyleURL(for: .cycling),
            center: route.path.first,
            zoom: 13,
            route: route.path,
            markers: markers,
            interactive: false,
            onMarkerTap: { marker in
                guard let poi = route.pois.first(where: { Self.identifier(for: $0) == marker.id }) else { return }
                onSelect(poi)
            },
            camera: camera
        )
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(alignment: .bottom) {
            if let focused {
                StopCallout(poi: focused, units: units, onClose: onClearFocus)
                    .padding(8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if route.pois.isEmpty {
                Text("No stops on this one")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.Colors.cream.opacity(0.92), in: Capsule())
                    .padding(8)
            }
        }
        .accessibilityIdentifier("route.map")
    }

    private var markers: [MapMarker] {
        route.pois.prefix(10).map { poi in
            MapMarker(
                id: Self.identifier(for: poi),
                coordinate: poi.coordinate,
                kind: poi.id == focused?.id ? .stopActive : .stop,
                title: poi.name,
                symbol: DiscoveryIcon.symbol(for: poi.category)
            )
        }
    }

    private static func identifier(for poi: RoutePOI) -> String { "stop-\(poi.id.uuidString)" }
}

/// The stop under the rider's finger: what it is, how far in, what the detour costs.
struct StopCallout: View {
    let poi: RoutePOI
    let units: Units
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DiscoveryIcon.symbol(for: poi.category))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Colors.cream)
                .frame(width: 30, height: 30)
                .background(DiscoveryIcon.color(for: poi.category), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(poi.name)
                    .font(Theme.Typography.text(14, .bold))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.muted)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Close stop")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onClose == nil ? 14 : 4)
        .padding(.vertical, 7)
        .background(Theme.Colors.cream, in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.2), radius: 8, y: 3)
        .accessibilityIdentifier("stopCallout")
    }

    private var detail: String {
        let formatter = UnitFormatter(units: units)
        var parts = [poi.category.rawValue.lowercased()]
        if poi.requested == true { parts.append("you asked for this") }
        parts.append("\(formatter.distance(meters: poi.routePositionMeters)) in")
        if poi.detourMeters > 20 { parts.append("+\(formatter.distance(meters: poi.detourMeters))") }
        return parts.joined(separator: " · ")
    }
}
