import RoadsAndRunesCore
import SwiftUI

@MainActor
@Observable
final class SocialViewModel {
    private(set) var friends: [FriendSummary] = []
    private(set) var requests = FriendRequests()
    private(set) var feed: [FeedEvent] = []
    private(set) var parties: [Party] = []
    var error: String?
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    func load() async {
        do {
            friends = try await container.api.friends()
            requests = try await container.api.friendRequests()
            feed = (try? await container.api.feed().items) ?? []
            if container.session.isEnabled("party_quests") { parties = (try? await container.api.parties()) ?? [] }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func sendRequest(userId: UUID) async {
        do { _ = try await container.api.sendFriendRequest(userId: userId); await load() } catch { self.error = error.localizedDescription }
    }

    func respond(_ request: FriendRequest, accept: Bool) async {
        do {
            requests = accept ? try await container.api.acceptFriendRequest(id: request.id) : try await container.api.declineFriendRequest(id: request.id)
            if accept { container.analytics.track(.friendAdded, properties: ["userId": request.user.id.uuidString]) }
            friends = (try? await container.api.friends()) ?? friends
        } catch { self.error = error.localizedDescription }
    }

    func remove(_ friend: FriendSummary) async {
        try? await container.api.removeFriend(userId: friend.id)
        await load()
    }
}

struct FriendsView: View {
    @Environment(AppContainer.self) private var container
    @State private var model: SocialViewModel?
    @State private var newFriendId = ""

    var body: some View {
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if let error = model.error { Text(error).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ember) }
                    if !model.requests.incoming.isEmpty {
                        SectionHeader(title: "Requests")
                        ForEach(model.requests.incoming) { request in
                            HStack {
                                FriendCard(friend: request.user)
                                VStack {
                                    Button("Accept") { Task { await model.respond(request, accept: true) } }.buttonStyle(.borderedProminent).tint(Theme.Colors.moss)
                                    Button("Decline") { Task { await model.respond(request, accept: false) } }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    SectionHeader(title: "Friends")
                    if model.friends.isEmpty { Text("Add friends by their user id to plan shared adventures.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary) }
                    ForEach(model.friends) { friend in
                        NavigationLink { ProfileView(userId: friend.id) } label: { FriendCard(friend: friend) }.buttonStyle(.plain)
                            .contextMenu { Button("Remove friend", role: .destructive) { Task { await model.remove(friend) } } }
                    }
                    HStack {
                        TextField("Friend's user id", text: $newFriendId).textFieldStyle(.roundedBorder)
                        Button("Add") { if let id = UUID(uuidString: newFriendId) { Task { await model.sendRequest(userId: id); newFriendId = "" } } }.buttonStyle(.bordered)
                    }
                    if !model.requests.outgoing.isEmpty {
                        Text("\(model.requests.outgoing.count) request\(model.requests.outgoing.count == 1 ? "" : "s") pending").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                    }
                    if !model.feed.isEmpty {
                        SectionHeader(title: "Activity")
                        ForEach(model.feed) { event in
                            HStack {
                                Image(systemName: icon(for: event.eventType)).foregroundStyle(Theme.Colors.rune)
                                Text("\(event.user.displayName) \(text(for: event))").font(Theme.Typography.body)
                                Spacer()
                            }
                            .card()
                        }
                    }
                    if container.session.isEnabled("party_quests") {
                        SectionHeader(title: "Parties")
                        ForEach(model.parties) { PartyCard(party: $0) }
                    }
                }
                .padding(Theme.Spacing.md)
            }
        }
        .background(Theme.Colors.parchment)
        .navigationTitle("Friends")
        .task {
            if model == nil { model = SocialViewModel(container: container) }
            await model?.load()
        }
    }

    private func icon(for type: FeedEventType) -> String {
        switch type {
        case .friendQuestCompleted: return "scroll"
        case .friendDiscovery: return "sparkles"
        case .friendLevelUp: return "arrow.up.circle"
        case .friendNewRegion: return "map"
        default: return "bell"
        }
    }

    private func text(for event: FeedEvent) -> String {
        switch event.eventType {
        case .friendQuestCompleted:
            if case .string(let title)? = event.payload["questTitle"] { return "completed \(title)" }
            return "completed a quest"
        case .friendDiscovery:
            if case .string(let name)? = event.payload["name"] { return "discovered \(name)" }
            return "made a discovery"
        case .friendLevelUp:
            if case .number(let level)? = event.payload["to"] { return "reached level \(Int(level))" }
            return "levelled up"
        case .friendNewRegion: return "explored a new region"
        default: return "did something"
        }
    }
}

struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    let userId: UUID
    @State private var profile: PublicProfile?

    var body: some View {
        ScrollView {
            if let profile {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.md) {
                        Circle().fill(Theme.Colors.parchmentDeep).frame(width: 64, height: 64).overlay(Text(String(profile.displayName.prefix(1))).font(Theme.Typography.title))
                        VStack(alignment: .leading) {
                            Text(profile.displayName).font(Theme.Typography.title)
                            Text([profile.title, profile.characterClass?.rawValue.capitalized, profile.overallLevel.map { "Level \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    HStack(spacing: Theme.Spacing.lg) {
                        RideMetric(title: "Quests", value: "\(profile.questsCompleted)", compact: true)
                        RideMetric(title: "Discoveries", value: "\(profile.discoveriesFound)", compact: true)
                        RideMetric(title: "Terrain", value: profile.favouriteTerrain?.capitalized ?? "–", compact: true)
                    }
                    .card()
                    if !profile.recentAdventures.isEmpty {
                        SectionHeader(title: "Recent adventures")
                        ForEach(profile.recentAdventures, id: \.rideId) { adventure in
                            HStack {
                                Text(adventure.questTitle ?? "Ride").font(Theme.Typography.heading)
                                Spacer()
                                Text("+\(adventure.xpAwarded) XP").foregroundStyle(Theme.Colors.moss)
                            }
                            .card()
                        }
                    }
                }
                .padding(Theme.Spacing.md)
            } else { ProgressView() }
        }
        .background(Theme.Colors.parchment)
        .navigationBarTitleDisplayMode(.inline)
        .task { profile = try? await container.api.profile(userId: userId) }
    }
}
