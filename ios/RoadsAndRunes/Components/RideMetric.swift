import SwiftUI

struct RideMetric: View {
    let title: String
    let value: String
    var compact = false
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.Colors.textSecondary)
            Text(value).font(compact ? Theme.Typography.heading.monospacedDigit() : Theme.Typography.metric)
                .foregroundStyle(accent ? Theme.Colors.rune : Theme.Colors.textPrimary)
        }
    }
}

/// Navigation-mode metric: white on black, large digits.
struct NavMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Theme.Colors.navForeground)
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(Theme.Colors.navForeground.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
}
