import Foundation
import Observation
import RoadsAndRunesCore

/// The districts (0.9.0): those passed through, for the Journal and the World's
/// quiet labels, and the one the player stands in, for Next up. A server from
/// before 0.9.0 has none, and nothing is shown.
@MainActor
@Observable
final class DistrictStore {
    private(set) var districts: [District] = []
    /// False until the server has answered once, and on a server without districts.
    private(set) var available = false
    private(set) var loaded = false
    /// The district at the player's position, asked at most once a minute and 300 m.
    private(set) var here: District?
    var error: String?

    @ObservationIgnored private let api: any RoadsAndRunesAPI
    @ObservationIgnored private var lastAsked: (at: Date, from: Coordinate)?
    @ObservationIgnored private var asking = false

    static let hereInterval: TimeInterval = 60
    static let hereMovedMeters = 300.0

    init(api: any RoadsAndRunesAPI) {
        self.api = api
    }

    func refresh() async {
        do {
            districts = try await api.districts()
            available = true
            error = nil
        } catch let failure as APIError where failure.isNotFound {
            available = false
            districts = []
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// One district's page, with its ledger.
    func page(id: String) async throws -> District {
        let district = try await api.district(id: id)
        if let index = districts.firstIndex(where: { $0.id == id }) { districts[index] = district }
        return district
    }

    /// Which district the player is in, when they have moved and a minute has passed.
    func noticePosition(_ position: Coordinate, now: Date = Date()) async {
        guard !asking else { return }
        if let lastAsked, now.timeIntervalSince(lastAsked.at) < Self.hereInterval || GeoMath.distance(lastAsked.from, position) <= Self.hereMovedMeters {
            return
        }
        lastAsked = (now, position)
        asking = true
        defer { asking = false }
        do {
            here = try await api.districtHere(at: position)
        } catch {
            // No signal, or a server without districts: the last answer stands.
        }
    }

    /// Fresh numbers after a journey: its districts may have moved on.
    func journeyEnded(_ summary: AdventureSummary) async {
        guard summary.districts?.isEmpty == false || available else { return }
        lastAsked = nil
        await refresh()
    }

    /// The labels for the World map: the districts passed through, by name.
    var labels: [MapLabel] {
        districts.filter { $0.latitude != 0 || $0.longitude != 0 }.map { MapLabel(id: "district-\($0.id)", coordinate: $0.coordinate, text: $0.name) }
    }

    /// Next up's district line: the one here, when it is near a milestone.
    var milestoneLine: String? { here.flatMap { DistrictCopy.nearMilestone($0) } }
}
