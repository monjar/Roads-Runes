import RoadsAndRunesCore
import SwiftUI

/// Route alternative as a stacked card (design 2a): colour bar, Caprasimo
/// label, three numbers, surface strip, then "why this route" in one line.
struct RouteCard: View {
    let route: RouteOption
    let selected: Bool
    let units: Units
    var bestMatch = false
    /// Overrides "Best match", e.g. "Quest route" for the quest's fixed route.
    var badge: String?

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    var body: some View {
        HStack(spacing: 14) {
            colorBar
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(route.label).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    if let badge = badge ?? (bestMatch ? "Best match" : nil) {
                        Text(badge)
                            .font(Theme.Typography.eyebrow)
                            .foregroundStyle(Theme.Colors.cream)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Theme.Colors.terracotta, in: Capsule())
                    } else if route.engine == "synthetic" {
                        Eyebrow(text: "Preview", color: Theme.Colors.terracottaDeep)
                    }
                }
                HStack(spacing: 14) {
                    Text(formatter.distance(meters: route.distanceMeters))
                    Text(formatter.duration(seconds: Double(route.estimatedDurationSeconds)))
                    Text("↑ \(formatter.elevation(meters: route.elevationGainMeters))")
                }
                .font(Theme.Typography.text(14, .semibold))
                .foregroundStyle(Theme.Colors.ink)
                SurfaceBar(surface: route.surface).frame(height: 7)
                Text(whyThisRoute).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(2)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).stroke(selected ? Theme.Colors.terracotta : .clear, lineWidth: 2))
    }

    @ViewBuilder
    private var colorBar: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        switch RouteStyle.of(route.label) {
        case .fast:
            shape.fill(Theme.Colors.mutedLight)
                .mask { VStack(spacing: 3) { ForEach(0..<12, id: \.self) { _ in Rectangle().frame(height: 5) } } }
                .frame(width: 6)
        case .relaxed:
            shape.fill(Theme.Colors.sage).frame(width: 6)
        case .adventure:
            shape.fill(Theme.Colors.terracotta).frame(width: 6)
        }
    }

    private var whyThisRoute: String {
        var parts: [String] = []
        let gravel = Int((route.surface.gravel + route.surface.trail) * 100)
        if gravel > 0 { parts.append("\(gravel)% gravel") } else { parts.append("almost entirely paved") }
        if !route.climbs.isEmpty { parts.append("\(route.climbs.count) climb\(route.climbs.count == 1 ? "" : "s")") } else { parts.append("gentle") }
        parts.append("\(Int(route.cyclewayFraction * 100))% cycleways and quiet roads")
        if route.newTerritoryFraction > 0.05 { parts.append("\(Int(route.newTerritoryFraction * 100))% new to you") }
        if let poi = route.pois.first {
            parts.append("\(poi.name) at \(formatter.distance(meters: poi.routePositionMeters))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Functional colour for the three labelled alternatives: terracotta is the
/// selected route, sage the Relaxed alternative, dashed grey the Fast one.
enum RouteStyle {
    case relaxed, adventure, fast

    static func of(_ label: String) -> RouteStyle {
        switch label.lowercased() {
        case "relaxed", "gentle", "easy", "scenic": return .relaxed
        case "fast", "direct", "quick": return .fast
        default: return .adventure
        }
    }

    var color: Color {
        switch self {
        case .relaxed: return Theme.Colors.sage
        case .adventure: return Theme.Colors.terracotta
        case .fast: return Theme.Colors.mutedLight
        }
    }
}

/// Surface strip: paved ink, compact gravel green, loose gravel dotted terracotta
/// (so it survives colour-blindness), unknown in the line colour.
struct SurfaceBar: View {
    let surface: SurfaceBreakdown

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            let segments: [(Double, Color, Bool)] = [
                (surface.paved, Theme.Colors.inkSoft, false),
                (surface.gravel, Theme.Colors.compactGravel, false),
                (surface.trail, Theme.Colors.terracotta, true),
            ]
            for (fraction, color, dotted) in segments {
                let width = size.width * CGFloat(max(0, fraction))
                if dotted {
                    var dx = x
                    while dx < x + width {
                        let w = min(3, x + width - dx)
                        context.fill(Path(CGRect(x: dx, y: 0, width: w, height: size.height)), with: .color(color))
                        dx += 5
                    }
                } else {
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(color))
                }
                x += width
            }
            if x < size.width {
                context.fill(Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)), with: .color(Theme.Colors.line))
            }
        }
        .clipShape(Capsule())
    }
}

/// Elevation profile: sage area under an ink line, with the steepest climb in terracotta.
struct ElevationSparkline: View {
    let samples: [ElevationSample]
    var highlight: Climb? = nil

    var body: some View {
        GeometryReader { geo in
            let elevations = samples.map(\.elevationMeters)
            if let minE = elevations.min(), let maxE = elevations.max(), samples.count > 1 {
                let range = max(maxE - minE, 10)
                let total = max(samples.last?.distanceMeters ?? 1, 1)
                let points: [CGPoint] = samples.map { s in
                    CGPoint(
                        x: geo.size.width * CGFloat(s.distanceMeters / total),
                        y: geo.size.height * (1 - CGFloat((s.elevationMeters - minE) / range)) * 0.9 + geo.size.height * 0.05
                    )
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height))
                        for p in points { path.addLine(to: p) }
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(Theme.Colors.sage.opacity(0.28))
                    Path { path in
                        for (i, p) in points.enumerated() {
                            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    }
                    .stroke(Theme.Colors.inkSoft, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    if let highlight {
                        let start = CGFloat(highlight.startMeters / total)
                        let end = CGFloat((highlight.startMeters + highlight.lengthMeters) / total)
                        Path { path in
                            for (i, s) in samples.enumerated() where s.distanceMeters >= highlight.startMeters && s.distanceMeters <= highlight.startMeters + highlight.lengthMeters {
                                if path.isEmpty { path.move(to: points[i]) } else { path.addLine(to: points[i]) }
                            }
                        }
                        .stroke(Theme.Colors.terracotta, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        Rectangle()
                            .fill(Theme.Colors.terracotta.opacity(0.08))
                            .frame(width: max(0, (end - start) * geo.size.width))
                            .position(x: (start + end) / 2 * geo.size.width, y: geo.size.height / 2)
                    }
                }
            }
        }
    }
}

/// Stop on the route (design 3a): "The Crown · pub · 26.0 km in · +600 m, +3 min".
struct RouteStopRow: View {
    let poi: RoutePOI
    let units: Units

    var body: some View {
        let f = UnitFormatter(units: units)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.Colors.terracotta)
                Image(systemName: DiscoveryIcon.symbol(for: poi.category)).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.Colors.cream)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(poi.name) · \(poi.category.rawValue.lowercased())").font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                Text("\(f.distance(meters: poi.routePositionMeters)) in · +\(f.distance(meters: poi.detourMeters)), +\(max(1, poi.detourSeconds / 60)) min")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}
