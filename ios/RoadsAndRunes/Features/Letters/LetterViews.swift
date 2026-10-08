import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// "Leave a letter": a line to your future self, left where you are (at a
/// standstill on a ride) or at a place on the map (0.7.3). It is never sent to
/// anyone, and comes back only if you pass within 60 m a season or more later.
struct LetterSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let coordinate: Coordinate
    /// The place's name, when it was left from a place card.
    var placeName: String?
    var onLeft: (Letter) -> Void = { _ in }
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var writing: Bool

    private var count: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow(text: placeName.map { "A letter at \($0)" } ?? "A letter here", color: Theme.Colors.terracottaDeep)
                Spacer()
                IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34) { dismiss() }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("letter.close")
            }
            Text("Leave a letter").font(Theme.Typography.voice(26, relativeTo: .title)).foregroundStyle(Theme.Colors.ink)
            Text("A note to your future self. Pass here again a season or more from now and Journey's end will show it to you. No one else ever sees it.")
                .font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            TextField("What's worth remembering here?", text: $text, axis: .vertical)
                .font(Theme.Typography.text(17))
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(3...6)
                .focused($writing)
                .padding(14)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .onChange(of: text) { _, new in
                    if new.count > LetterRules.maxLength { text = String(new.prefix(LetterRules.maxLength)) }
                }
                .accessibilityIdentifier("letter.text")
            HStack {
                if let error { ErrorLine(text: error) }
                Spacer()
                Text("\(count) / \(LetterRules.maxLength)")
                    .font(Theme.Typography.caption.monospacedDigit())
                    .foregroundStyle(count > LetterRules.maxLength ? Theme.Colors.terracottaDeep : Theme.Colors.muted)
                    .accessibilityIdentifier("letter.count")
            }
            Spacer(minLength: 0)
            Button {
                Task { await send() }
            } label: {
                ZStack {
                    Text("Leave a letter").opacity(sending ? 0 : 1)
                    if sending { ProgressView().tint(Theme.Colors.cream) }
                }
            }
            .buttonStyle(.primary)
            .disabled(sending || LetterRules.cleaned(text) == nil)
            .accessibilityIdentifier("letter.send")
        }
        .padding(22)
        .background(Theme.Colors.cream.ignoresSafeArea())
        .onAppear { writing = true }
    }

    private func send() async {
        guard let cleaned = LetterRules.cleaned(text) else { return }
        sending = true
        defer { sending = false }
        do {
            let letter = try await container.api.writeLetter(LetterCreate(at: coordinate, text: cleaned))
            onLeft(letter)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The letters you have left, newest first: what, where, when, and when one was
/// found again. In the Journal.
struct LettersView: View {
    @Environment(AppContainer.self) private var container
    @State private var letters: [Letter] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Leave one at a standstill on a journey, or from a place on the map. It comes back when you pass there a season or more later.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let error { ErrorLine(text: error) }
                if loaded, letters.isEmpty, error == nil {
                    EmptyState(icon: .quillInk, title: "No letters yet",
                               message: "Stop somewhere on a journey, or open a place on the map, and leave one.")
                        .accessibilityIdentifier("letters.empty")
                }
                ForEach(letters) { letter in
                    LetterRow(letter: letter)
                        .contextMenu {
                            Button(role: .destructive) { Task { await delete(letter) } } label: { Label("Delete letter", systemImage: "trash") }
                        }
                }
                if !loaded { ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity) }
            }
            .padding(22)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .navigationTitle("Letters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .hidesTabBar()
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            letters = try await container.api.letters().sorted { $0.writtenAt > $1.writtenAt }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func delete(_ letter: Letter) async {
        do {
            try await container.api.deleteLetter(id: letter.id)
            letters.removeAll { $0.id == letter.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LetterRow: View {
    let letter: Letter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\u{201C}\(letter.text)\u{201D}")
                .font(Theme.Typography.text(15)).italic().foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                MarkView(.icon(.quillInk, spot: .terracotta)).frame(width: 14, height: 14)
                Text(Self.where(letter)).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.inkSoft).lineLimit(1)
                Text("· \(letter.writtenAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            if let shown = letter.shownAt {
                Label("Shown on \(shown.formatted(date: .abbreviated, time: .omitted))", systemImage: "envelope.open")
                    .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                    .accessibilityIdentifier("letter.shown")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("letterRow")
    }

    static func `where`(_ letter: Letter) -> String {
        if let name = letter.placeName, !name.isEmpty { return "At \(name)" }
        return "Where you stopped"
    }
}

/// Journey's end: letters written here a season or more ago, found again.
struct FoundLettersSection: View {
    let letters: [FoundLetter]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(letters.enumerated()), id: \.offset) { _, letter in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        MarkView(.icon(.quillInk, spot: .terracotta)).frame(width: 18, height: 18)
                        Text(letter.shownLine()).font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.terracottaDeep)
                    }
                    Text("\u{201C}\(letter.text)\u{201D}")
                        .font(Theme.Typography.text(15)).italic().foregroundStyle(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let place = letter.placeName, !place.isEmpty {
                        Text("At \(place)").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.letters")
    }
}
