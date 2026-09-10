import RoadsAndRunesCore
import SwiftUI

enum DiscoveryIcon {
    static func symbol(for category: DiscoveryCategory) -> String {
        switch category {
        case .nature: return "leaf.fill"
        case .historical: return "building.columns.fill"
        case .cultural: return "theatermasks.fill"
        case .food: return "fork.knife"
        case .pub: return "mug.fill"
        case .cafe: return "cup.and.saucer.fill"
        case .viewpoint: return "binoculars.fill"
        case .cycling: return "bicycle"
        case .landmark: return "mappin.and.ellipse"
        case .trail: return "figure.hiking"
        default: return "sparkle"
        }
    }

    /// Kinds of discovery share the app's four hues: natural sage, historical
    /// ink blue, cultural and stops terracotta, viewpoints dusk violet.
    static func color(for category: DiscoveryCategory) -> Color {
        switch category {
        case .nature, .trail, .cycling: return Theme.Colors.sage
        case .historical, .landmark: return Theme.Colors.scribe
        case .cultural, .food, .pub, .cafe: return Theme.Colors.terracotta
        case .viewpoint: return Theme.Colors.wizard
        default: return Theme.Colors.mutedLight
        }
    }

    static func group(for category: DiscoveryCategory) -> String {
        switch category {
        case .nature, .trail, .viewpoint: return "Natural"
        case .historical, .landmark: return "Historical"
        case .cultural, .food, .pub, .cafe: return "Cultural"
        case .cycling: return "Cycling"
        default: return "Other"
        }
    }
}

/// Discovery as a row: category circle, name, category.
struct DiscoveryCard: View {
    let discovery: DiscoverySummary
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(DiscoveryIcon.color(for: discovery.category))
                Image(systemName: DiscoveryIcon.symbol(for: discovery.category)).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.Colors.cream)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(discovery.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                Text(subtitle ?? discovery.category.rawValue.capitalized).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if discovery.discoveredByUser {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Theme.Colors.sageDeep)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

/// Discovery in the Journal's collection grid (design 14b).
struct DiscoveryTile: View {
    let name: String
    let category: DiscoveryCategory
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Circle().fill(DiscoveryIcon.color(for: category))
                Image(systemName: DiscoveryIcon.symbol(for: category)).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.Colors.cream)
            }
            .frame(width: 26, height: 26)
            Text(name).font(Theme.Typography.voice(16, relativeTo: .headline)).foregroundStyle(Theme.Colors.ink).lineLimit(2)
            Text(subtitle).font(Theme.Typography.text(11.5, relativeTo: .caption2)).foregroundStyle(Theme.Colors.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }
}

/// Friends are initials on their class colour, set in the companion voice.
struct FriendAvatar: View {
    let name: String
    let characterClass: CharacterClass?
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            Circle().fill(ClassStyle.color(characterClass ?? .unknown))
            Text(String(name.prefix(1)).uppercased())
                .font(Theme.Typography.voice(size * 0.38, relativeTo: .title3))
                .foregroundStyle(Theme.Colors.cream)
        }
        .frame(width: size, height: size)
    }
}

struct FriendCard: View {
    let friend: FriendSummary

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(name: friend.displayName, characterClass: friend.characterClass, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let characterClass = friend.characterClass, let level = friend.overallLevel {
            parts.append("\(ClassStyle.name(characterClass)) — Level \(level)")
        } else if let level = friend.overallLevel {
            parts.append("Level \(level)")
        }
        if let title = friend.title { parts.append("“\(title)”") }
        return parts.isEmpty ? "Adventurer" : parts.joined(separator: " · ")
    }
}

struct PartyCard: View {
    let party: Party

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Party").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Eyebrow(text: party.status.rawValue, color: Theme.Colors.terracottaDeep)
            }
            HStack(spacing: -8) {
                ForEach(party.members.prefix(5)) { member in
                    FriendAvatar(name: member.user.displayName, characterClass: member.user.characterClass, size: 30)
                        .overlay(Circle().stroke(Theme.Colors.surface, lineWidth: 2))
                }
            }
            Text(party.members.map { $0.user.displayName }.joined(separator: ", ")).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        }
        .card()
    }
}
