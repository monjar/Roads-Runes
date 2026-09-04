import RoadsAndRunesCore
import SwiftUI

struct RouteCard: View {
    let route: RouteOption
    let selected: Bool
    let units: Units

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text(route.label).font(Theme.Typography.heading)
                Spacer()
                if route.engine == "synthetic" {
                    Text("PREVIEW").font(Theme.Typography.caption.weight(.bold)).foregroundStyle(Theme.Colors.ember)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Theme.Colors.moss : Theme.Colors.textSecondary)
            }
            ElevationSparkline(samples: route.elevationSamples).frame(height: 36)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Theme.Spacing.xs) {
                RideMetric(title: "Distance", value: formatter.distance(meters: route.distanceMeters), compact: true)
                RideMetric(title: "Time", value: formatter.duration(seconds: Double(route.estimatedDurationSeconds)), compact: true)
                RideMetric(title: "Climb", value: formatter.elevation(meters: route.elevationGainMeters), compact: true)
                RideMetric(title: "New territory", value: "\(Int(route.newTerritoryFraction * 100))%", compact: true)
                RideMetric(title: "Cycleways", value: "\(Int(route.cyclewayFraction * 100))%", compact: true)
                RideMetric(title: "Traffic", value: trafficLabel, compact: true)
            }
            HStack(spacing: Theme.Spacing.sm) {
                SurfaceBar(surface: route.surface).frame(height: 6)
            }
            if !route.pois.isEmpty {
                Text(route.pois.prefix(3).map(\.name).joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary).lineLimit(1)
            }
        }
        .card()
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(selected ? Theme.Colors.moss : .clear, lineWidth: 2))
    }

    private var formatter: UnitFormatter { UnitFormatter(units: units) }

    private var trafficLabel: String {
        switch route.trafficExposure {
        case ..<0.2: return "Low"
        case ..<0.5: return "Medium"
        default: return "High"
        }
    }
}

struct SurfaceBar: View {
    let surface: SurfaceBreakdown

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                segment(width: geo.size.width * surface.paved, color: Theme.Colors.ink.opacity(0.6))
                segment(width: geo.size.width * surface.gravel, color: Theme.Colors.rune)
                segment(width: geo.size.width * surface.trail, color: Theme.Colors.moss)
                segment(width: geo.size.width * surface.unknown, color: Theme.Colors.textSecondary.opacity(0.3))
            }
            .clipShape(Capsule())
        }
    }

    private func segment(width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, width))
    }
}

struct ElevationSparkline: View {
    let samples: [ElevationSample]

    var body: some View {
        GeometryReader { geo in
            let elevations = samples.map(\.elevationMeters)
            if let minE = elevations.min(), let maxE = elevations.max(), samples.count > 1 {
                let range = max(maxE - minE, 10)
                Path { path in
                    for (i, s) in samples.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(samples.count - 1)
                        let y = geo.size.height * (1 - CGFloat((s.elevationMeters - minE) / range))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Theme.Colors.river, lineWidth: 2)
            }
        }
    }
}
