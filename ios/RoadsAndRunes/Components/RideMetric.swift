import SwiftUI

/// A number a rider reads: Figtree 700, label beneath in the muted colour.
struct RideMetric: View {
    let title: String
    let value: String
    var compact = false
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font((compact ? Theme.Typography.number : Theme.Typography.numberLarge).monospacedDigit())
                .foregroundStyle(accent ? Theme.Colors.sageDeep : Theme.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
        }
    }
}

/// Navigation-mode metric inside the ink stats pill: cream digits, quiet label.
struct NavMetric: View {
    let title: String
    let value: String
    var accent = false
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(value)
                .font(Theme.Typography.numberLarge.monospacedDigit())
                .foregroundStyle(accent ? Theme.Colors.sageLight : Theme.Colors.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title).font(Theme.Typography.text(11, relativeTo: .caption2)).foregroundStyle(Theme.Colors.line).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }
}
