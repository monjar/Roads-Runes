import MapKit
import RoadsAndRunesCore
import SwiftUI

/// The World's search pill: magnifier, prompt, and the rider's emblem with
/// their level (opens Character), like an account avatar on a maps app.
struct WorldSearchBar: View {
    let character: Character?
    let onSearch: () -> Void
    let onCharacter: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSearch) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.Colors.muted)
                    Text("Search places").font(Theme.Typography.text(16)).foregroundStyle(Theme.Colors.muted)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Search places")
            if let character {
                Button(action: onCharacter) {
                    ClassEmblem(characterClass: character.characterClass, size: 36)
                        .overlay(alignment: .bottomTrailing) {
                            Text("\(character.overallLevel)")
                                .font(Theme.Typography.text(10, .bold))
                                .foregroundStyle(Theme.Colors.cream)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Theme.Colors.ink, in: Capsule())
                                .offset(x: 4, y: 3)
                        }
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("\(character.name), level \(character.overallLevel)")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 54)
        .background(Theme.Colors.cream, in: Capsule())
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 8, y: 3)
    }
}

/// Cafés · Pubs · Parks … under the search bar; the active one is ink.
struct PlaceShortcutChips: View {
    var active: PlaceShortcut?
    let onSelect: (PlaceShortcut) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PlaceShortcut.allCases) { shortcut in
                    Button { onSelect(shortcut) } label: {
                        Label(shortcut.title, systemImage: shortcut.symbol)
                            .font(Theme.Typography.text(13, .semibold))
                            .foregroundStyle(active == shortcut ? Theme.Colors.cream : Theme.Colors.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(active == shortcut ? Theme.Colors.ink : Theme.Colors.cream, in: Capsule())
                            .shadow(color: Theme.Colors.ink.opacity(0.14), radius: 3, y: 1)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

/// The selected place: what it is, how far, and one action — ride there.
struct PlaceCard: View {
    let place: Place
    var distanceMeters: Double?
    let units: Units
    let onDirections: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                PlaceIcon(symbol: place.symbol, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name).font(Theme.Typography.voice(20, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                    if !facts.isEmpty {
                        Text(facts).font(Theme.Typography.text(13, .semibold)).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                    }
                    if let address = place.address {
                        Text(address).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34, action: onClose)
                    .accessibilityLabel("Close")
            }
            Button(action: onDirections) {
                HStack(spacing: 10) {
                    Image(systemName: "bicycle")
                    Text("Ride here")
                }
            }
            .buttonStyle(.primary)
        }
        .padding(18)
        .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 4)
    }

    private var facts: String {
        var parts: [String] = []
        if let category = place.category { parts.append(category) }
        if let distanceMeters { parts.append("\(UnitFormatter(units: units).distance(meters: distanceMeters)) away") }
        return parts.joined(separator: " · ")
    }
}

/// Results of a shortcut or a typed search, nearest first.
struct PlaceResultsCard: View {
    let title: String
    let places: [Place]
    var origin: Coordinate?
    let units: Units
    var isLoading = false
    let onSelect: (Place) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title).font(Theme.Typography.voice(20, relativeTo: .title3)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                if isLoading { ProgressView().tint(Theme.Colors.terracotta) }
                Spacer()
                IconCircleButton(symbol: "xmark", background: Theme.Colors.surface, size: 34, action: onClose)
                    .accessibilityLabel("Clear results")
            }
            if places.isEmpty && !isLoading {
                Text("Nothing found here. Move the map and try again.").font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(places) { place in
                        Button { onSelect(place) } label: {
                            PlaceRow(place: place, distanceMeters: origin.map { GeoMath.distance($0, place.coordinate) }, units: units)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("placeRow")
                    }
                }
            }
        }
        .padding(18)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.Colors.cream, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(color: Theme.Colors.ink.opacity(0.18), radius: 12, y: 4)
    }
}

struct PlaceRow: View {
    let place: Place
    var distanceMeters: Double?
    let units: Units

    var body: some View {
        HStack(spacing: 12) {
            PlaceIcon(symbol: place.symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                if let detail = place.address ?? place.category {
                    Text(detail).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let distanceMeters {
                Text(UnitFormatter(units: units).distance(meters: distanceMeters)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PlaceIcon: View {
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(Theme.Colors.terracottaDeep)
            .frame(width: size, height: size)
            .background(Theme.Colors.terracottaTint, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Full-screen search: suggestions as you type, shortcuts when empty,
/// Return searches the visible region for everything matching.
struct PlaceSearchScreen: View {
    @Bindable var search: PlaceSearch
    let onPick: (MKLocalSearchCompletion) -> Void
    let onSubmit: (String) -> Void
    let onShortcut: (PlaceShortcut) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.Colors.ink).frame(width: 36, height: 36)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Back to map")
                TextField("Search places", text: $search.query)
                    .font(Theme.Typography.text(17))
                    .foregroundStyle(Theme.Colors.ink)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit {
                        let text = search.query.trimmingCharacters(in: .whitespaces)
                        if !text.isEmpty { onSubmit(text) }
                    }
                if !search.query.isEmpty {
                    Button { search.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.Colors.mutedLight)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 54)
            .background(Theme.Colors.surface, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.query.isEmpty {
                        ForEach(PlaceShortcut.allCases) { shortcut in
                            Button { onShortcut(shortcut) } label: { row(symbol: shortcut.symbol, title: shortcut.title, subtitle: "Near the map") }
                                .buttonStyle(.pressable)
                        }
                    } else {
                        ForEach(search.suggestions, id: \.self) { suggestion in
                            Button { onPick(suggestion) } label: { row(symbol: "mappin", title: suggestion.title, subtitle: suggestion.subtitle) }
                                .buttonStyle(.pressable)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.Colors.cream.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func row(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.Colors.inkSoft)
                .frame(width: 36, height: 36)
                .background(Theme.Colors.surface, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.text(15, .semibold)).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Colors.track).frame(height: 1).padding(.leading, 50) }
    }
}
