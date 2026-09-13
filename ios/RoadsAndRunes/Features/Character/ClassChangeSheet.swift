import RoadsAndRunesCore
import SwiftUI

/// Change class from Settings. The first change is free — a class picked before a
/// single ride is a guess — and after that it costs coins and waits a day, so a
/// class is a choice rather than a toggle. Level, XP, coins and discoveries stay;
/// each class keeps its own level for when the rider comes back to it.
struct ClassChangeSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var classes: [ClassInfo] = []
    @State private var selected: CharacterClass?
    @State private var saving = false
    @State private var error: String?

    private var character: Character? { container.session.character }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.Colors.cream.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Eyebrow(text: "Change class", color: Theme.Colors.terracottaDeep)
                        Spacer()
                        IconCircleButton(symbol: "xmark", background: Theme.Colors.surface) { dismiss() }.accessibilityLabel("Close")
                    }
                    Text("Who do you\nride as now?").font(Theme.Typography.voice(32, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                    Text(terms).font(Theme.Typography.text(13.5)).foregroundStyle(Theme.Colors.muted).lineSpacing(2)
                    ForEach(classes) { info in
                        let value = info.characterClass
                        let current = value == character?.characterClass
                        Button {
                            if info.enabled, !current { withAnimation(.snappy) { selected = value } }
                        } label: {
                            ClassCard(info: info, selected: selected == value && info.enabled)
                                .overlay(alignment: .topTrailing) {
                                    if current {
                                        Eyebrow(text: "Now", color: Theme.Colors.muted).padding(16)
                                    } else if let level = character?.classProgress?[value.rawValue]?.classLevel {
                                        Eyebrow(text: "Level \(level) kept", color: Theme.Colors.sageDeep).padding(16)
                                    }
                                }
                        }
                        .buttonStyle(.pressable)
                        .disabled(current)
                        .accessibilityIdentifier("classChange.\(value.rawValue.lowercased())")
                    }
                    if let error { ErrorLine(text: error) }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 110)
            }
            Button {
                guard let selected else { return }
                saving = true
                Task {
                    error = await container.session.changeClass(to: selected)
                    saving = false
                    if error == nil { dismiss() }
                }
            } label: {
                Text(saving ? "Changing…" : buttonTitle)
            }
            .buttonStyle(.primary)
            .disabled(selected == nil || saving || !allowedNow)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .accessibilityIdentifier("classChange.confirm")
        }
        .task {
            classes = (try? await container.api.classes()) ?? []
        }
    }

    private var allowedNow: Bool {
        guard let next = character?.nextClassChangeAt else { return true }
        return next <= Date()
    }

    private var terms: String {
        guard let character else { return "" }
        let cost = character.classChangeCostAC ?? 0
        if let next = character.nextClassChangeAt, next > Date() {
            return "You changed class recently. The next change opens \(next.formatted(.relative(presentation: .named)))."
        }
        let price = cost == 0 ? "This change is free" : "This change costs \(cost) Active Coins (you have \(character.activeCoins ?? 0))"
        return "\(price). Your level, XP, coins and discoveries stay; each class keeps its own level for when you come back to it."
    }

    private var buttonTitle: String {
        guard let selected else { return "Pick a class" }
        let cost = character?.classChangeCostAC ?? 0
        return cost == 0 ? "Become \(ClassStyle.name(selected))" : "Become \(ClassStyle.name(selected)) for \(cost) AC"
    }
}
