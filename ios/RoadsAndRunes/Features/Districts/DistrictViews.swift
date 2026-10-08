import RoadsAndRunesArt
import RoadsAndRunesCore
import SwiftUI

/// Districts in the Journal (0.9.0): every named area passed through, how much of
/// it is explored (a percentage once its roads are known, else a count of tiles),
/// whether it is yours and what it pays.
struct DistrictsSection: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        let store = container.districts
        VStack(alignment: .leading, spacing: 10) {
            Text("A district is yours at 50% explored while you keep visiting. It pays coins every week.")
                .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.error, store.districts.isEmpty { ErrorLine(text: error) }
            if store.loaded, store.districts.isEmpty {
                EmptyState(icon: .village, title: "No districts yet",
                           message: "Ride, run or walk through a named part of town to add it here.")
                    .accessibilityIdentifier("districts.empty")
            }
            ForEach(store.districts) { district in
                NavigationLink { DistrictPage(district: district) } label: { DistrictRow(district: district) }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("districtRow")
            }
            if !store.loaded {
                ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal.districts")
        .task { await store.refresh() }
    }
}

/// One district: its name and title, how far explored, Yours, what it pays.
struct DistrictRow: View {
    let district: District

    var body: some View {
        HStack(spacing: 12) {
            PercentRing(percent: district.percent, tiles: district.exploredTiles, size: 46, yours: district.yours)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(district.name).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                    if district.yours { YoursBadge() }
                }
                Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if district.yours {
                HStack(spacing: 3) {
                    MarkView(.coin).frame(width: 13, height: 13)
                    Text("\(district.weeklyCoins)/week").font(Theme.Typography.captionStrong.monospacedDigit())
                }
                .foregroundStyle(Theme.Colors.terracottaDeep)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(LoreCopy.purse(district.weeklyCoins)) a week")
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.muted)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    }

    private var subtitle: String {
        var parts: [String] = []
        let title = DistrictCopy.fullName(name: district.name, title: district.title, percent: district.percent)
        if let comma = title.range(of: ", ") { parts.append(String(title[comma.upperBound...])) }
        parts.append(district.progressLine)
        if district.completed { parts.append("complete") } else if district.wasYours, !district.yours { parts.append("was yours") }
        return parts.joined(separator: " · ")
    }
}

/// "Yours", in sage.
struct YoursBadge: View {
    var body: some View {
        Text("Yours")
            .font(Theme.Typography.text(11, .bold))
            .foregroundStyle(Theme.Colors.sageText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.Colors.sageTint, in: Capsule())
            .accessibilityIdentifier("district.yours")
    }
}

/// How far a district is explored: a ring with its percentage, or (until its roads
/// are known) a plain ring with the count of tiles. Marks at 50% and 90%.
struct PercentRing: View {
    let percent: Double?
    let tiles: Int
    var size: CGFloat = 46
    var yours = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.Colors.track, lineWidth: size * 0.11)
            if let percent {
                Circle()
                    .trim(from: 0, to: min(1, max(0, percent / 100)))
                    .stroke(yours || percent >= DistrictRules.yoursAtPercent ? Theme.Colors.sageDeep : Theme.Colors.terracotta,
                            style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ForEach([DistrictRules.yoursAtPercent, DistrictRules.completeAtPercent], id: \.self) { mark in
                    Capsule().fill(Theme.Colors.ink.opacity(0.45))
                        .frame(width: 1.5, height: size * 0.16)
                        .offset(y: -size / 2 + size * 0.055)
                        .rotationEffect(.degrees(mark / 100 * 360))
                }
            }
            VStack(spacing: 0) {
                Text(percent.map { "\(Int(max(0, min(100, $0)).rounded(.down)))%" } ?? "\(tiles)")
                    .font(Theme.Typography.text(size * 0.27, .bold).monospacedDigit())
                    .foregroundStyle(Theme.Colors.ink)
                    .minimumScaleFactor(0.6)
                if percent == nil, size >= 80 {
                    Text(tiles == 1 ? "tile" : "tiles").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
            }
            .padding(size * 0.14)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DistrictCopy.progress(percent: percent, tiles: tiles))
    }
}

/// A district's page: its name and title, the ring, whether it is yours, its
/// ledger, the first and last visit, and one button to plan a ride there.
struct DistrictPage: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    let district: District
    @State private var page: District?
    @State private var error: String?
    @State private var planning = false

    private var shown: District { page ?? district }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    IconCircleButton(symbol: "chevron.left", background: Theme.Colors.surface) { dismiss() }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("district.back")
                    Spacer()
                    Eyebrow(text: shown.kind.map { $0.capitalized } ?? "District", color: Theme.Colors.sageDeep)
                }
                HStack(alignment: .center, spacing: 16) {
                    PercentRing(percent: shown.percent, tiles: shown.exploredTiles, size: 96, yours: shown.yours)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(shown.name).font(Theme.Typography.voice(30, relativeTo: .largeTitle)).foregroundStyle(Theme.Colors.ink)
                            .lineLimit(2).minimumScaleFactor(0.7)
                        Text(titleLine).font(Theme.Typography.text(16, .semibold)).italic().foregroundStyle(Theme.Colors.terracottaDeep)
                            .accessibilityIdentifier("district.title")
                        Text(shown.progressLine).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                            .accessibilityIdentifier("district.progress")
                    }
                }
                if shown.completed {
                    Label(DistrictCopy.complete, systemImage: "checkmark.seal.fill")
                        .font(Theme.Typography.captionStrong).foregroundStyle(Theme.Colors.sageDeep)
                        .accessibilityIdentifier("district.complete")
                }
                if let standing = standingLine {
                    Text(standing).font(Theme.Typography.text(14)).foregroundStyle(Theme.Colors.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("district.standing")
                }
                if shown.percent == nil {
                    Text("The percentage shows once the roads and paths here are known.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
                }
                if let error { ErrorLine(text: error) }
                ledger
                VStack(alignment: .leading, spacing: 4) {
                    if let first = DistrictCopy.visit("First visit", shown.firstVisit) { visitLine(first) }
                    if let last = DistrictCopy.visit("Last visit", shown.lastVisit) { visitLine(last) }
                }
                .accessibilityIdentifier("district.visits")
                Button { planning = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: container.session.defaultActivity.symbol)
                        Text(DistrictCopy.planButton)
                    }
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("district.plan")
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, Theme.Layout.tabBarClearance)
        }
        .background(Theme.Colors.cream)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $planning) { RoutePlannerView(quest: nil, destination: Self.place(for: shown)) }
        .task {
            do {
                page = try await container.districts.page(id: district.id)
                error = nil
            } catch {
                self.error = "Couldn't load this district's ledger. Pull to try again."
            }
        }
        .refreshable {
            page = try? await container.districts.page(id: district.id)
        }
    }

    /// ", the Riverlands", or ", in the fog".
    private var titleLine: String {
        let full = shown.fullName
        guard let comma = full.range(of: ", ") else { return DistrictCopy.inTheFog }
        return String(full[comma.upperBound...])
    }

    private var standingLine: String? {
        if shown.yours { return DistrictCopy.yours(shown.name, weeklyCoins: shown.weeklyCoins) }
        return DistrictCopy.standing(shown)
    }

    @ViewBuilder
    private var ledger: some View {
        if let ledger = shown.ledger {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                FactTile(value: "\(ledger.placesFound)", label: ledger.placesFound == 1 ? "Place found" : "Places found")
                FactTile(value: "\(ledger.creaturesDefeated)", label: ledger.creaturesDefeated == 1 ? "Creature defeated" : "Creatures defeated")
                FactTile(value: "\(ledger.runesCut)", label: ledger.runesCut == 1 ? "Rune ride" : "Rune rides")
                FactTile(value: "\(ledger.questsDone)", label: ledger.questsDone == 1 ? "Quest done" : "Quests done")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("district.ledger")
        } else if page == nil, error == nil {
            ProgressView().tint(Theme.Colors.terracotta).frame(maxWidth: .infinity)
        }
    }

    private func visitLine(_ text: String) -> some View {
        Text(text).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
    }

    /// The district's middle as somewhere to ride to.
    static func place(for district: District) -> Place {
        Place(id: "district-\(district.id)", name: district.name, category: "District", address: nil, mark: .token(.village, ring: .sage),
              coordinate: district.coordinate, source: .pin)
    }
}
