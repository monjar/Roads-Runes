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

    // MARK: Finding people

    private(set) var found: [FriendSummary] = []
    private(set) var searching = false

    /// People by name. Two letters is the least the server will look for.
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { found = []; return }
        searching = true
        found = (try? await container.api.searchUsers(query: trimmed)) ?? []
        searching = false
    }

    /// Where this person stands with me, so the search row shows the right button.
    func standing(of person: FriendSummary) -> FriendshipState {
        if friends.contains(where: { $0.id == person.id }) { return .friends }
        if requests.outgoing.contains(where: { $0.user.id == person.id }) { return .requestSent }
        if requests.incoming.contains(where: { $0.user.id == person.id }) { return .requestReceived }
        return .none
    }

    // MARK: Parties

    /// Parties I have been asked into and not yet answered.
    var invitations: [Party] {
        guard let me = container.session.user?.id else { return [] }
        return parties.filter { party in
            party.status == .forming && party.members.contains { $0.user.id == me && $0.status == "INVITED" }
        }
    }

    func acceptInvite(_ party: Party) async {
        do { _ = try await container.api.acceptPartyInvite(id: party.id); await load() } catch { self.error = error.localizedDescription }
    }
}

/// Friends (design 15b): the light feed — "look where people went". Nearby
/// adventurers as a count only; exact locations are never shared.
struct FriendsView: View {
    @ViewBuilder
    private func searchAction(_ person: FriendSummary, _ model: SocialViewModel) -> some View {
        switch model.standing(of: person) {
        case .friends:
            Text("Friends").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        case .requestSent:
            Text("Sent").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
        case .requestReceived:
            Button("Accept") {
                Task {
                    if let request = model.requests.incoming.first(where: { $0.user.id == person.id }) { await model.respond(request, accept: true) }
                }
            }
            .buttonStyle(.inkPill)
        default:
            Button("Add") { Task { await model.sendRequest(userId: person.id) } }.buttonStyle(.inkPill)
        }
    }

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: SocialViewModel?
    @State private var query = ""
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
                        TextField("Search by name", text: $query)
                            .textFieldStyle(CreamFieldStyle())
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, text in Task { await model.search(text) } }
                        if model.found.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2, !model.searching {
                            Text("Nobody by that name yet.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                        ForEach(model.found) { person in
                            HStack(spacing: 8) {
                                FriendAvatar(name: person.displayName, characterClass: person.characterClass, size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(person.displayName).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                                    if let level = person.overallLevel {
                                        Text("Level \(level)\(person.characterClass.map { " · \(ClassStyle.name($0))" } ?? "")")
                                            .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                                    }
                                }
                                Spacer()
                                searchAction(person, model)
                            }
                            .card(radius: Theme.Radius.row)
                        }
                        if !model.requests.outgoing.isEmpty {
                            Text("\(model.requests.outgoing.count) request\(model.requests.outgoing.count == 1 ? "" : "s") pending").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }

                    if container.session.isEnabled("party_quests"), !model.invitations.isEmpty {
                        SectionHeader(title: "You're invited")
                        ForEach(model.invitations) { party in
                            NavigationLink { PartyDetailView(partyId: party.id) } label: {
                                PartyCard(party: party)
                            }
                            .buttonStyle(.pressable)
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
                                .buttonStyle(.pressable)
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
                            .buttonStyle(.pressable)
                        }
                    }
                    if model.friends.isEmpty {
                        Text("Find friends by name to plan shared adventures and see where they went.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }

                    if !model.feed.isEmpty {
                        Text("Look where people went").font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink).padding(.top, 4)
                        ForEach(model.feed) { event in
                            FeedRow(event: event)
                        }
                    }
                    if container.session.isEnabled("party_quests"), !model.parties.isEmpty {
                        SectionHeader(title: "Parties")
                        ForEach(model.parties.filter { party in !model.invitations.contains { $0.id == party.id } }) { party in
                            NavigationLink { PartyDetailView(partyId: party.id) } label: { PartyCard(party: party) }
                                .buttonStyle(.pressable)
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, Theme.Layout.tabBarClearance)
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
        .hidesTabBar()
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
                        .buttonStyle(.pressable)
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

/// One party: who is in, where each of them stands, the quest, and what I can
/// do about it — which depends on whether I lead it and where it has got to.
///
/// FORMING: invitees answer, joined members mark ready, the leader can start
/// once someone is in or cancel. READY: everyone joined is ready; the leader
/// starts. ACTIVE: the ride is on; leaving is the only exit. The server owns
/// the transitions (`social/service.py`); this screen only offers the ones it
/// will accept.
struct PartyDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let partyId: UUID
    @State private var party: Party?
    @State private var quest: Quest?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingLeave = false

    private var me: UUID? { container.session.user?.id }
    private var mine: PartyMember? { party?.members.first { $0.user.id == me } }
    private var leading: Bool { party?.ownerId == me }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    IconCircleButton(symbol: "chevron.left", background: Theme.Colors.surface) { dismiss() }
                    Text("Party").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                    if let party { Eyebrow(text: statusWord(party.status), color: Theme.Colors.terracottaDeep) }
                }
                if let error { ErrorLine(text: error) }
                if let party {
                    if let quest {
                        QuestCard(quest: quest, compact: true, units: container.session.units)
                    }
                    Text(party.completionRule == .group ? "Everyone finishes together: the quest completes when the last of you does." : "Each of you finishes on your own ride; the party is company.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)

                    SectionHeader(title: "Riders")
                    ForEach(party.members) { member in
                        HStack(spacing: 10) {
                            FriendAvatar(name: member.user.displayName, characterClass: member.user.characterClass, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.user.displayName + (member.user.id == me ? " (you)" : "")).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                                Text(member.role == "OWNER" ? "Leads the party" : memberWord(member.status)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                            }
                            Spacer()
                            Image(systemName: memberSymbol(member.status)).foregroundStyle(member.status == "READY" ? Theme.Colors.sageDeep : Theme.Colors.muted)
                        }
                        .card(radius: Theme.Radius.row)
                    }

                    actions(party)
                } else {
                    ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Leave this party?", isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button(leading ? "Cancel the party" : "Leave", role: .destructive) { Task { await act { try await container.api.leaveParty(id: partyId) } } }
            Button("Stay", role: .cancel) {}
        } message: {
            Text(leading ? "You lead it, so leaving ends it for everyone." : "The others ride on without you.")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func actions(_ party: Party) -> some View {
        VStack(spacing: 10) {
            if mine?.status == "INVITED", party.status == .forming {
                Button("Join the party") { Task { await act { try await container.api.acceptPartyInvite(id: partyId) } } }.buttonStyle(.primary)
            } else if mine?.status == "JOINED", party.status == .forming {
                Button("I'm ready") { Task { await act { try await container.api.readyParty(id: partyId) } } }.buttonStyle(.primary)
            }
            if leading, party.status == .forming || party.status == .ready {
                let joined = party.members.filter { $0.status == "JOINED" || $0.status == "READY" }.count
                Button(party.status == .ready ? "Start the ride" : "Start with whoever is in (\(joined))") {
                    Task { await act { try await container.api.startParty(id: partyId) } }
                }
                .buttonStyle(party.status == .ready ? .primary : .surfacePill)
                .disabled(joined < 1)
            }
            if party.status == .forming || party.status == .ready || party.status == .active {
                Button(leading ? "Cancel the party" : "Leave the party", role: .destructive) { confirmingLeave = true }.buttonStyle(.surfacePill)
            }
        }
        .disabled(busy)
        .padding(.top, 6)
    }

    private func act(_ call: () async throws -> Party) async {
        busy = true
        do { party = try await call(); error = nil } catch { self.error = error.localizedDescription }
        busy = false
    }

    private func load() async {
        do {
            party = try await container.api.party(id: partyId)
            if let questId = party?.questId { quest = try? await container.api.quest(id: questId) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func statusWord(_ status: PartyStatus) -> String {
        switch status {
        case .forming: return "Forming"
        case .ready: return "Ready"
        case .active: return "Riding"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .unknown: return "Party"
        }
    }

    private func memberWord(_ status: String) -> String {
        switch status {
        case "INVITED": return "Invited, not yet answered"
        case "JOINED": return "In, not yet ready"
        case "READY": return "Ready to ride"
        case "LEFT": return "Left"
        default: return status.capitalized
        }
    }

    private func memberSymbol(_ status: String) -> String {
        switch status {
        case "INVITED": return "envelope"
        case "JOINED": return "person.fill"
        case "READY": return "checkmark.circle.fill"
        case "LEFT": return "figure.walk.departure"
        default: return "person"
        }
    }
}
