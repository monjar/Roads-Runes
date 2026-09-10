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
            if accept {
                requests = try await container.api.acceptFriendRequest(id: request.id)
            } else {
                requests = try await container.api.declineFriendRequest(id: request.id)
            }
            if accept { container.analytics.track(.friendAdded, properties: ["userId": request.user.id.uuidString]) }
            friends = (try? await container.api.friends()) ?? friends
        } catch { self.error = error.localizedDescription }
    }

    func remove(_ friend: FriendSummary) async {
        try? await container.api.removeFriend(userId: friend.id)
        await load()
    }
}

/// Friends (design 15b): the light feed — "look where people went". Nearby
/// adventurers as a count only; exact locations are never shared.
struct FriendsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: SocialViewModel?
    @State private var newFriendId = ""
    @State private var showAdd = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            if let model {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        IconCircleButton(symbol: "chevron.left", background: Theme.Colors.surface) { dismiss() }
                        Text("Friends").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                        Spacer()
                        Button(showAdd ? "Done" : "Add") { withAnimation(.snappy) { showAdd.toggle() } }
                            .font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.terracottaDeep)
                    }
                    if let error = model.error { ErrorLine(text: error) }

                    privacyCard

                    if showAdd {
                        HStack(spacing: 8) {
                            TextField("Friend's user id", text: $newFriendId).textFieldStyle(CreamFieldStyle())
                            Button("Send") {
                                if let id = UUID(uuidString: newFriendId) { Task { await model.sendRequest(userId: id); newFriendId = "" } }
                            }
                            .buttonStyle(.inkPill)
                        }
                        if !model.requests.outgoing.isEmpty {
                            Text("\(model.requests.outgoing.count) request\(model.requests.outgoing.count == 1 ? "" : "s") pending").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }

                    if !model.requests.incoming.isEmpty {
                        SectionHeader(title: "Requests")
                        ForEach(model.requests.incoming) { request in
                            HStack(spacing: 8) {
                                FriendAvatar(name: request.user.displayName, characterClass: request.user.characterClass, size: 40)
                                Text(request.user.displayName).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                                Spacer()
                                Button("Accept") { Task { await model.respond(request, accept: true) } }.buttonStyle(.inkPill)
                                Button("Decline") { Task { await model.respond(request, accept: false) } }.buttonStyle(.surfacePill)
                            }
                            .card(radius: Theme.Radius.row)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(model.friends) { friend in
                                NavigationLink { ProfileView(userId: friend.id) } label: {
                                    VStack(spacing: 6) {
                                        FriendAvatar(name: friend.displayName, characterClass: friend.characterClass)
                                        Text(friend.displayName).font(Theme.Typography.text(12, relativeTo: .caption)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                                    }
                                    .frame(width: 64)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button("Remove friend", role: .destructive) { Task { await model.remove(friend) } } }
                            }
                            Button { withAnimation(.snappy) { showAdd = true } } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle().strokeBorder(Theme.Colors.hatch, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.Colors.muted)
                                    }
                                    .frame(width: 52, height: 52)
                                    Text("Invite").font(Theme.Typography.text(12, relativeTo: .caption)).foregroundStyle(Theme.Colors.muted)
                                }
                                .frame(width: 64)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if model.friends.isEmpty {
                        Text("Add friends by their user id to plan shared adventures and see where they went.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }

                    if !model.feed.isEmpty {
                        Text("Look where people went").font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink).padding(.top, 4)
                        ForEach(model.feed) { event in
                            FeedRow(event: event)
                        }
                    }
                    if container.session.isEnabled("party_quests"), !model.parties.isEmpty {
                        SectionHeader(title: "Parties")
                        ForEach(model.parties) { PartyCard(party: $0) }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.Colors.cream)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if model == nil { model = SocialViewModel(container: container) }
            await model?.load()
        }
    }

    private var visibleToFriends: Binding<Bool> {
        Binding(
            get: { container.session.settings.defaultRideVisibility != .privateOnly },
            set: { visible in
                var settings = container.session.settings
                settings.defaultRideVisibility = visible ? .friends : .privateOnly
                Task { await container.session.update(settings: settings) }
            }
        )
    }

    private var privacyCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Exact locations are never shared").font(Theme.Typography.label).foregroundStyle(Theme.Colors.ink)
                Text("Friends see finished adventures, never where you are.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer()
            VStack(spacing: 4) {
                Toggle("Rides visible to friends", isOn: visibleToFriends).labelsHidden().tint(Theme.Colors.sage)
                Text("Visible").font(Theme.Typography.text(11, .semibold, relativeTo: .caption2)).foregroundStyle(Theme.Colors.muted)
            }
        }
        .card(radius: Theme.Radius.row)
    }
}

struct FeedRow: View {
    let event: FeedEvent

    var body: some View {
        HStack(spacing: 12) {
            FriendAvatar(name: event.user.displayName, characterClass: event.user.characterClass, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                (Text(event.user.displayName).font(Theme.Typography.text(13.5, .bold)) + Text(" \(verb) ").font(Theme.Typography.text(13.5)) + Text(object).font(Theme.Typography.text(13.5, .bold)))
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(2)
                Text(event.createdAt.formatted(.relative(presentation: .named))).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private var verb: String {
        switch event.eventType {
        case .friendQuestCompleted: return "completed"
        case .friendDiscovery: return "discovered"
        case .friendLevelUp: return "reached"
        case .friendNewRegion: return "explored"
        default: return "did"
        }
    }

    private var object: String {
        switch event.eventType {
        case .friendQuestCompleted:
            if case .string(let title)? = event.payload["questTitle"] { return title }
            return "a quest"
        case .friendDiscovery:
            if case .string(let name)? = event.payload["name"] { return name }
            return "a new place"
        case .friendLevelUp:
            if case .number(let level)? = event.payload["to"] { return "level \(Int(level))" }
            return "a new level"
        case .friendNewRegion:
            if case .string(let region)? = event.payload["region"] { return region }
            return "a new region"
        default: return "something"
        }
    }
}

/// A friend's profile (design 15a): exploration personality, no pace anywhere.
/// One action: invite to a quest. Location is never shown.
struct ProfileView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let userId: UUID
    @State private var profile: PublicProfile?
    @State private var busy = false
    @State private var error: String?
    @State private var showInvite = false

    private var color: Color { ClassStyle.color(profile?.characterClass ?? .unknown) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Colors.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                color.frame(height: 260).frame(maxWidth: .infinity).ignoresSafeArea(edges: .top)
                Spacer(minLength: 0)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    header
                    if let profile {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                FactTile(value: "\(profile.questsCompleted)", label: "Quests")
                                FactTile(value: "\(profile.discoveriesFound)", label: "Discoveries")
                                FactTile(value: profile.overallLevel.map { "\($0)" } ?? "—", label: "Level")
                            }
                            HStack(spacing: 10) {
                                smallTile("Favourite terrain", profile.favouriteTerrain?.capitalized ?? "Unknown yet")
                                smallTile("Friendship", friendshipText(profile.friendship))
                            }
                            if !profile.recentAdventures.isEmpty {
                                SectionHeader(title: "Recent adventures", subtitle: "\(profile.recentAdventures.count)")
                                ForEach(profile.recentAdventures, id: \.rideId) { adventure in
                                    recentRow(adventure)
                                }
                            }
                            if let error { ErrorLine(text: error) }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .padding(.bottom, 110)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sheetSurface()
                        .offset(y: -26)
                    } else {
                        ProgressView().tint(Theme.Colors.terracotta).padding(.top, 40)
                    }
                }
            }
            if let profile { actionButton(profile).padding(.horizontal, 20).padding(.bottom, 8) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { profile = try? await container.api.profile(userId: userId) }
        .sheet(isPresented: $showInvite) { PartyInviteSheet(userId: userId) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                IconCircleButton(symbol: "chevron.left", background: Theme.Colors.cream.opacity(0.18), foreground: Theme.Colors.cream) { dismiss() }
                Spacer()
                Text(sinceText).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.cream.opacity(0.85))
            }
            HStack(spacing: 16) {
                if let profile {
                    if let characterClass = profile.characterClass, characterClass != .unknown {
                        ClassEmblem(characterClass: characterClass, size: 76, inverted: true)
                    } else {
                        ZStack {
                            Circle().fill(Theme.Colors.cream)
                            Text(String(profile.displayName.prefix(1)).uppercased()).font(Theme.Typography.voice(30)).foregroundStyle(color)
                        }
                        .frame(width: 76, height: 76)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).lineLimit(1).minimumScaleFactor(0.7)
                        if let characterClass = profile.characterClass, let level = profile.overallLevel {
                            Text("\(ClassStyle.name(characterClass)) — Level \(level)").font(Theme.Typography.text(14, .semibold))
                        }
                        if let title = profile.title { Text("“\(title)”").font(Theme.Typography.caption).opacity(0.85) }
                    }
                }
            }
        }
        .foregroundStyle(Theme.Colors.cream)
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sinceText: String {
        guard let profile else { return "" }
        switch profile.friendship {
        case .friends: return "Friends"
        case .requestSent: return "Request sent"
        case .requestReceived: return "Wants to be friends"
        default: return "Adventurer"
        }
    }

    private func friendshipText(_ state: FriendshipState) -> String {
        switch state {
        case .friends: return "Friends"
        case .requestSent: return "Request sent"
        case .requestReceived: return "Request received"
        case .blocked: return "Blocked"
        default: return "Not yet"
        }
    }

    private func smallTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.Typography.text(11, relativeTo: .caption2)).foregroundStyle(Theme.Colors.muted)
            Text(value).font(Theme.Typography.text(13.5, .bold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private func recentRow(_ adventure: AdventureSummaryPublic) -> some View {
        let f = UnitFormatter(units: container.session.units)
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.Colors.track)
                Image(systemName: "sparkle").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.Colors.muted)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(adventure.questTitle ?? "Free ride").font(Theme.Typography.voice(16, relativeTo: .headline)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                Text("\(adventure.completedAt.formatted(.relative(presentation: .named))) · \(f.distance(meters: adventure.distanceMeters)) · \(f.distance(meters: adventure.newTerritoryMeters)) new · +\(adventure.xpAwarded) XP")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    @ViewBuilder
    private func actionButton(_ profile: PublicProfile) -> some View {
        switch profile.friendship {
        case .friends:
            if container.session.isEnabled("party_quests") {
                Button("Invite to a quest") { showInvite = true }.buttonStyle(.primary)
            }
        case .none, .unknown:
            Button(busy ? "Sending…" : "Send a friend request") {
                busy = true
                Task {
                    do { _ = try await container.api.sendFriendRequest(userId: userId); self.profile = try? await container.api.profile(userId: userId) } catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
            .buttonStyle(.primary)
            .disabled(busy)
        case .requestReceived:
            Button("Accept friend request") {
                Task {
                    if let request = (try? await container.api.friendRequests())?.incoming.first(where: { $0.user.id == userId }) {
                        _ = try? await container.api.acceptFriendRequest(id: request.id)
                        self.profile = try? await container.api.profile(userId: userId)
                    }
                }
            }
            .buttonStyle(.primary)
        default:
            EmptyView()
        }
    }
}

/// Pick one of your accepted quests and form a party with this friend.
struct PartyInviteSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let userId: UUID
    @State private var quests: [Quest] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHandle().frame(maxWidth: .infinity)
            Text("Invite to a quest").font(Theme.Typography.title).foregroundStyle(Theme.Colors.ink)
            if quests.isEmpty {
                Text("Accept a quest first, then invite friends to ride it together.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(quests) { quest in
                        Button {
                            Task {
                                do {
                                    _ = try await container.api.createParty(PartyCreate(questId: quest.id, memberIds: [userId]))
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            QuestCard(quest: quest, compact: true, units: container.session.units)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let error { ErrorLine(text: error) }
        }
        .padding(22)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.Colors.cream)
        .task {
            let origin = container.location.lastFix?.coordinate ?? SampleData.origin
            let accepted = (try? await container.api.quests(near: origin, status: .accepted, limit: 10, cursor: nil))?.items ?? []
            let active = (try? await container.api.quests(near: origin, status: .active, limit: 5, cursor: nil))?.items ?? []
            quests = accepted + active
        }
    }
}
