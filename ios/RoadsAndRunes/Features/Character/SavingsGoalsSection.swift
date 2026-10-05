import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Savings goals on the coin history page (0.7.3): a real reward set against
/// coins ("New bar tape" at 5,000), each a bar against the purse. Kept on this
/// phone only, and nothing more than that.
struct SavingsGoalsSection: View {
    let purse: Int
    var store = SavingsGoalStore()
    @State private var goals: [SavingsGoal] = []
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Savings goals", subtitle: goals.isEmpty ? nil : "\(goals.count)")
            if goals.isEmpty {
                Text("Set a real reward against your coins, like new bar tape at 5,000.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            ForEach(goals) { goal in
                row(goal)
                    .contextMenu {
                        Button(role: .destructive) { remove(goal) } label: { Label("Remove goal", systemImage: "trash") }
                    }
            }
            Button { adding = true } label: {
                Label("Add a savings goal", systemImage: "plus")
            }
            .buttonStyle(.surfacePill)
            .accessibilityIdentifier("savings.add")
        }
        .onAppear { goals = store.load() }
        .sheet(isPresented: $adding) {
            AddSavingsGoalSheet { name, coins in
                guard store.add(name: name, coins: coins) != nil else { return false }
                goals = store.load()
                return true
            }
            .presentationDetents([.medium])
        }
    }

    private func row(_ goal: SavingsGoal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.name).font(Theme.Typography.text(14, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(goal.isReached(purse: purse) ? "Reached!" : "\(min(purse, goal.coins).formatted()) / \(goal.coins.formatted())")
                    .font(Theme.Typography.text(13, .semibold).monospacedDigit())
                    .foregroundStyle(goal.isReached(purse: purse) ? Theme.Colors.sageDeep : Theme.Colors.muted)
            }
            ProgressTrack(fraction: goal.fraction(purse: purse), fill: goal.isReached(purse: purse) ? Theme.Colors.sageDeep : Theme.Colors.gold, height: 8)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(goal.name), \(LoreCopy.purse(min(purse, goal.coins))) of \(LoreCopy.purse(goal.coins))")
        .accessibilityIdentifier("savings.row")
    }

    private func remove(_ goal: SavingsGoal) {
        store.remove(id: goal.id)
        goals = store.load()
    }
}

/// A name and a number of coins.
struct AddSavingsGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Keeps the goal; false when there is nothing to keep.
    let onAdd: (String, Int) -> Bool
    @State private var name = ""
    @State private var coins = ""

    private var amount: Int? { Int(coins.filter(\.isNumber)) }
    private var canAdd: Bool { SavingsGoal.make(name: name, coins: amount ?? 0) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow(text: "Savings goal", color: Theme.Colors.terracottaDeep)
                Spacer()
                IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34) { dismiss() }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("savings.close")
            }
            Text("What are you saving for?").font(Theme.Typography.voice(22, relativeTo: .title2)).foregroundStyle(Theme.Colors.ink)
            TextField("New bar tape", text: $name)
                .font(Theme.Typography.text(17))
                .padding(14)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .accessibilityIdentifier("savings.name")
            HStack(spacing: 8) {
                MarkView(.coin).frame(width: 20, height: 20)
                TextField("5,000", text: $coins)
                    .keyboardType(.numberPad)
                    .font(Theme.Typography.text(17))
                    .accessibilityIdentifier("savings.coins")
                Text("coins").font(Theme.Typography.text(15)).foregroundStyle(Theme.Colors.muted)
            }
            .padding(14)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            Text("It stays on this phone, as a bar against your purse.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            Spacer(minLength: 0)
            Button("Add goal") {
                if onAdd(name, amount ?? 0) { dismiss() }
            }
            .buttonStyle(.primary)
            .disabled(!canAdd)
            .accessibilityIdentifier("savings.save")
        }
        .padding(22)
        .background(Theme.Colors.cream.ignoresSafeArea())
    }
}
