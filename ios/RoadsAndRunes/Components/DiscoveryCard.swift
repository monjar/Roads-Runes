import RoadsAndRunesCore
import SwiftUI

struct DiscoveryCard: View {
    let discovery: DiscoverySummary

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: DiscoveryIcon.symbol(for: discovery.category)).font(.title2).foregroundStyle(Theme.Colors.river).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.name).font(Theme.Typography.heading)
                Text(discovery.category.rawValue.capitalized).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            if discovery.discoveredByUser {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.Colors.moss)
            }
        }
        .card()
    }
}

enum DiscoveryIcon {
    static func symbol(for category: DiscoveryCategory) -> String {
        switch category {
        case .nature: return "leaf"
        case .historical: return "building.columns"
        case .cultural: return "theatermasks"
        case .food: return "fork.knife"
        case .pub: return "mug"
        case .cafe: return "cup.and.saucer"
        case .viewpoint: return "binoculars"
        case .cycling: return "bicycle"
        case .landmark: return "mappin.and.ellipse"
        case .trail: return "figure.hiking"
        default: return "star"
        }
    }
}

struct FriendCard: View {
    let friend: FriendSummary

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Circle().fill(Theme.Colors.parchmentDeep).frame(width: 40, height: 40).overlay(Text(String(friend.displayName.prefix(1))).font(Theme.Typography.heading))
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName).font(Theme.Typography.heading)
                Text([friend.title, friend.overallLevel.map { "Level \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
        }
        .card()
    }
}

struct PartyCard: View {
    let party: Party

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Party").font(Theme.Typography.heading)
                Spacer()
                Text(party.status.rawValue.capitalized).font(Theme.Typography.caption.weight(.semibold)).foregroundStyle(Theme.Colors.rune)
            }
            Text(party.members.map { $0.user.displayName }.joined(separator: ", ")).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
        }
        .card()
    }
}
