import RoadsAndRunesCore
import SwiftUI

/// The arcs and where the rider stands in each (spec §21, phase 9).
///
/// The board is a different three quests every time and leads nowhere; an arc is
/// what the rider is in the middle of. So the ordering here is what is *live*
/// first, then what they could start, then what is still ahead of them — and the
/// ones they cannot reach yet are shown rather than hidden, because what is coming
/// is the reason to come back.
@MainActor
@Observable
final class StoryArcsModel {
    private(set) var arcs: [StoryArc] = []
    private(set) var loaded = false
    var error: String?
    private let container: AppContainer

    init(container: AppContainer) { self.container = container }

    func load() async {
        do {
            arcs = try await container.api.storyArcs()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Whatever is live, then what can be started, then what is still locked.
    var ordered: [StoryArc] {
        arcs.sorted { a, b in
            (rank(a), a.minLevel, a.title) < (rank(b), b.minLevel, b.title)
        }
    }

    private func rank(_ arc: StoryArc) -> Int {
        if arc.quests.contains(where: { $0.state == .open }) { return 0 }
        if arc.isComplete { return 3 }
        return arc.unlocked ? 1 : 2
    }
}

struct StoryArcsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var model: StoryArcsModel?
    var onOpenQuest: (UUID) -> Void = { _ in }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    IconCircleButton(symbol: "chevron.left", background: Theme.Colors.surface) { dismiss() }
                    Text("Story").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                    Spacer()
                }
                if let model {
                    if let error = model.error { ErrorLine(text: error) }
                    Text("Arcs are ridden in order: finishing a step is what opens the next. They wait for you — a step never expires.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    if model.loaded, model.arcs.isEmpty {
                        EmptyState(icon: "book.closed", title: "No arcs yet", message: "Story arcs will appear here.")
                    }
                    ForEach(model.ordered) { arc in ArcCard(arc: arc, onOpenQuest: onOpenQuest) }
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
        .task {
            if model == nil { model = StoryArcsModel(container: container) }
            await model?.load()
        }
        .refreshable { await model?.load() }
    }
}

private struct ArcCard: View {
    let arc: StoryArc
    let onOpenQuest: (UUID) -> Void

    private var accent: Color {
        arc.characterClass.map { ClassStyle.textColor($0) } ?? Theme.Colors.terracottaDeep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: eyebrow, color: accent)
                Spacer()
                Text("\(arc.completedCount)/\(arc.quests.count)")
                    .font(Theme.Typography.captionStrong)
                    .foregroundStyle(arc.isComplete ? Theme.Colors.sageDeep : Theme.Colors.muted)
            }
            Text(arc.title).font(Theme.Typography.heading).foregroundStyle(Theme.Colors.ink)
            Text(arc.description).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            if !arc.unlocked {
                Text(lockedReason).font(Theme.Typography.caption).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(arc.quests.enumerated()), id: \.element.id) { index, step in
                    StepRow(step: step, accent: accent, last: index == arc.quests.count - 1, onOpenQuest: onOpenQuest)
                }
            }
            .padding(.top, 2)
        }
        .card()
        .opacity(arc.unlocked ? 1 : 0.78)
    }

    private var eyebrow: String {
        if arc.isComplete { return "Complete" }
        guard let characterClass = arc.characterClass else { return "For anyone" }
        return "\(ClassStyle.name(characterClass)) arc"
    }

    private var lockedReason: String {
        guard let characterClass = arc.characterClass else { return "Opens at level \(arc.minLevel)." }
        return "For \(ClassStyle.name(characterClass))s, from class level \(arc.minLevel)."
    }
}

/// One step, drawn as a rung on the chain: the line between the dots is the arc.
private struct StepRow: View {
    let step: StoryStep
    let accent: Color
    let last: Bool
    let onOpenQuest: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                if !last {
                    Rectangle()
                        .fill(step.state == .completed ? tint.opacity(0.5) : Theme.Colors.hatch)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(step.state == .locked ? Theme.Colors.muted : Theme.Colors.ink)
                    .strikethrough(step.state == .completed, color: Theme.Colors.muted)
                // A locked step keeps its words: knowing what is coming is the point.
                Text(step.description).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                if step.state == .open, let questId = step.questId {
                    Button("On your board now") { onOpenQuest(questId) }
                        .font(Theme.Typography.captionStrong)
                        .foregroundStyle(accent)
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, last ? 0 : 12)
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch step.state {
        case .completed: return "checkmark.circle.fill"
        case .open: return "circle.circle.fill"
        case .ready: return "circle"
        case .locked, .unknown: return "lock.fill"
        }
    }

    private var tint: Color {
        switch step.state {
        case .completed: return Theme.Colors.sageDeep
        case .open: return accent
        case .ready: return Theme.Colors.ink
        case .locked, .unknown: return Theme.Colors.muted
        }
    }
}
