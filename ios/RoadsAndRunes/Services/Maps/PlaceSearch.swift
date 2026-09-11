import CoreLocation
import MapKit
import Observation
import RoadsAndRunesCore

/// Somewhere the rider can ride to: a search result, a base-map POI, one of
/// the game's discoveries or a dropped pin. The World's place card and
/// Directions only need this much.
struct Place: Identifiable, Hashable {
    enum Source: Hashable { case search, map, pin, discovery(UUID) }

    let id: String
    var name: String
    var category: String?
    var address: String?
    var symbol: String
    let coordinate: Coordinate
    let source: Source
}

/// One-tap searches under the World's search bar: the stops a cyclist looks for.
enum PlaceShortcut: String, CaseIterable, Identifiable {
    case cafes, pubs, parks, viewpoints, bikeShops, landmarks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cafes: return "Cafés"
        case .pubs: return "Pubs"
        case .parks: return "Parks"
        case .viewpoints: return "Viewpoints"
        case .bikeShops: return "Bike shops"
        case .landmarks: return "Landmarks"
        }
    }

    var symbol: String {
        switch self {
        case .cafes: return "cup.and.saucer.fill"
        case .pubs: return "mug.fill"
        case .parks: return "tree.fill"
        case .viewpoints: return "binoculars.fill"
        case .bikeShops: return "bicycle"
        case .landmarks: return "building.columns.fill"
        }
    }

    var query: String {
        switch self {
        case .cafes: return "coffee"
        case .pubs: return "pub"
        case .parks: return "park"
        case .viewpoints: return "viewpoint"
        case .bikeShops: return "bike shop"
        case .landmarks: return "landmark"
        }
    }
}

/// Place search through MapKit (no API key; the base map stays MapLibre):
/// as-you-type suggestions, full searches in the visible region, and the
/// address under a dropped pin.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { completer.queryFragment = query }
    }
    private(set) var suggestions: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    /// Bias suggestions towards what the rider is looking at.
    func focus(on box: BoundingBox) {
        completer.region = Self.region(box)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { suggestions = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { suggestions = [] }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async throws -> Place? {
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response.mapItems.first.map(Self.place(from:))
    }

    func search(_ text: String, in box: BoundingBox?) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.pointOfInterest, .address]
        if let box {
            request.region = Self.region(box)
            // "Search this area": without this MapKit treats the region as a hint and wanders.
            if #available(iOS 18.0, *) { request.regionPriority = .required }
        }
        return try await MKLocalSearch(request: request).start().mapItems.map(Self.place(from:))
    }

    /// "12 Rotherhithe Street, London" for a dropped pin; nil offline.
    static func address(of coordinate: Coordinate) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let parts = [street.isEmpty ? mark.name : street, mark.locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func place(from item: MKMapItem) -> Place {
        let mark = item.placemark
        let street = [mark.subThoroughfare, mark.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let address = [street.isEmpty ? nil : street, mark.locality].compactMap { $0 }.joined(separator: ", ")
        let (category, symbol) = describe(item.pointOfInterestCategory, name: item.name)
        let coordinate = Coordinate(latitude: mark.coordinate.latitude, longitude: mark.coordinate.longitude)
        return Place(
            id: String(format: "search-%.5f,%.5f-", coordinate.latitude, coordinate.longitude) + (item.name ?? ""),
            name: item.name ?? (address.isEmpty ? "Place" : address),
            category: category,
            address: address.isEmpty ? nil : address,
            symbol: symbol,
            coordinate: coordinate,
            source: .search
        )
    }

    static func place(from feature: MapFeature) -> Place {
        let (category, symbol) = describe(mapClass: feature.kind, subclass: feature.subkind)
        return Place(
            id: String(format: "map-%.5f,%.5f", feature.coordinate.latitude, feature.coordinate.longitude),
            name: feature.name, category: category, address: nil, symbol: symbol,
            coordinate: feature.coordinate, source: .map
        )
    }

    static func region(_ box: BoundingBox) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (box.minLat + box.maxLat) / 2, longitude: (box.minLon + box.maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.005, box.maxLat - box.minLat), longitudeDelta: max(0.005, box.maxLon - box.minLon))
        )
    }

    private static func describe(_ category: MKPointOfInterestCategory?, name: String?) -> (String?, String) {
        let lowered = name?.lowercased() ?? ""
        if lowered.contains("cycle") || lowered.contains("bike") || lowered.contains("bicycle") { return ("Bike shop", "bicycle") }
        switch category {
        case .cafe: return ("Café", "cup.and.saucer.fill")
        case .restaurant, .bakery, .foodMarket: return ("Food", "fork.knife")
        case .nightlife, .brewery, .winery: return ("Pub & bar", "mug.fill")
        case .park, .nationalPark, .beach, .campground: return ("Park", "tree.fill")
        case .museum, .theater: return ("Landmark", "building.columns.fill")
        case .store: return ("Shop", "bag.fill")
        case .publicTransport: return ("Transit", "tram.fill")
        case .restroom: return ("Toilets", "toilet.fill")
        default: return (nil, "mappin")
        }
    }

    /// OpenMapTiles `poi` class/subclass (the base map's labels) to a label and symbol.
    private static func describe(mapClass: String?, subclass: String?) -> (String?, String) {
        switch mapClass {
        case "cafe": return ("Café", "cup.and.saucer.fill")
        case "beer", "bar": return ("Pub & bar", "mug.fill")
        case "restaurant", "fast_food", "ice_cream", "bakery": return ("Food", "fork.knife")
        case "park", "garden", "campsite", "playground": return ("Park", "tree.fill")
        case "museum", "castle", "monument", "attraction", "art_gallery", "place_of_worship", "town_hall": return ("Landmark", "building.columns.fill")
        case "bicycle": return ("Bike shop", "bicycle")
        case "railway", "bus", "ferry_terminal": return ("Transit", "tram.fill")
        case "toilets": return ("Toilets", "toilet.fill")
        case "shop", "grocery", "clothing_store": return ("Shop", "bag.fill")
        default:
            let label = (subclass ?? mapClass)?.replacingOccurrences(of: "_", with: " ").capitalized
            return (label, "mappin")
        }
    }
}
