import RoadsAndRunesCore
import SwiftUI

/// Every title there is (docs/ROADMAP.md, 0.6.2): the earned ones to choose from,
/// the rest with how they are earned. A title is worn as soon as it is earned until
/// one is chosen here; "Wear the newest" lets go of the choice.
struct TitlesScreen: View {
    @Environment(AppContainer.self) private var container
    @State private var titles: [TitleInfo] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var saving: String?
    /// The server has no titles to list (one from before 0.6.2).
    @State private var missing = false

    private var pinned: Bool { container.session.character?.titlePinned == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if missing {
                    EmptyState(icon: "rosette", title: "Not on this server yet", message: "Titles to choose come with the next server update.")
                } else if let error {
                    ErrorLine(text: error)
                }
                Text("A title is worn as soon as it is earned, until you choose one.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                let earned = titles.filter(\.earned)
                if !earned.isEmpty {
                    SectionHeader(title: "Earned", subtitle: "\(earned.count) of \(titles.count)")
                    VStack(spacing: 0) {
                        ForEach(earned) { title in
                            Button { Task { await wear(title.worn && pinned ? nil : title.slug) } } label: { row(title) }
                                .buttonStyle(.pressable)
                                .disabled(saving != nil)
                                .accessibilityIdentifier("title.\(title.slug)")
                        }
                    }
                    .card()
                    if pinned {
                        Button("Wear the newest") { Task { await wear(nil) } }
                            .font(Theme.Typography.captionStrong)
                            .foregroundStyle(Theme.Colors.terracottaDeep)
                            .accessibilityIdentifier("titles.newest")
                    }
                }
                let ahead = titles.filter { !$0.earned }
                if !ahead.isEmpty {
                    SectionHeader(title: "Still to earn")
                    VStack(spacing: 0) {
                        ForEach(ahead) { row($0) }
                    }
                    .card()
                }
                if loaded, titles.isEmpty, !missing, error == nil {
                    EmptyState(icon: "rosette", title: "No titles yet", message: "Go out once and you are a Passer-by.")
                }
            }
            .padding(22)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("Titles")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(_ title: TitleInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: title.worn ? "rosette" : (title.earned ? "circle" : "lock.fill"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(title.worn ? Theme.Colors.terracottaDeep : Theme.Colors.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.name).font(Theme.Typography.text(15, .semibold))
                    .foregroundStyle(title.earned ? Theme.Colors.ink : Theme.Colors.muted)
                Text(title.worn ? (pinned ? "Worn, by choice" : "Worn") : title.how)
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            Spacer(minLength: 0)
            if saving == title.slug { ProgressView().tint(Theme.Colors.terracotta) }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            titles = try await container.api.titles()
            error = nil
        } catch let failure as APIError where failure.isNotFound {
            missing = true
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func wear(_ slug: String?) async {
        saving = slug ?? "newest"
        defer { saving = nil }
        do {
            _ = try await container.api.wearTitle(slug: slug)
            await container.session.refreshCharacter()
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
