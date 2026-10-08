import Foundation

// The parish (0.9.0): districts, the Atlas and the looks, small enough to hold in
// memory. Called inside `run`, so under the lock.
extension MockAPI {
    public func districts() async throws -> [District] {
        try await run {
            self.storedDistricts
                .map { district in
                    var district = district
                    district.ledger = nil
                    return district
                }
                .sorted { ($0.lastPassed ?? .distantPast) > ($1.lastPassed ?? .distantPast) }
        }
    }

    public func district(id: String) async throws -> District {
        try await run {
            guard var district = self.storedDistricts.first(where: { $0.id == id }) else { throw self.notFound("District") }
            district.ledger = district.ledger ?? DistrictLedger(
                placesFound: SampleData.sampleLedger.placesFound, creaturesDefeated: SampleData.sampleLedger.creaturesDefeated,
                runesCut: SampleData.sampleLedger.runesCut, questsDone: SampleData.sampleLedger.questsDone,
                firstPassed: district.firstPassed, lastPassed: district.lastPassed
            )
            return district
        }
    }

    /// The district whose middle is nearest, within 4 km (the server's rule for a tile).
    public func districtHere(at point: Coordinate) async throws -> District? {
        try await run {
            self.storedDistricts
                .map { ($0, GeoMath.distance($0.coordinate, point)) }
                .filter { $0.1 <= 4000 }
                .min { $0.1 < $1.1 }?.0
        }
    }

    public func atlas(year: Int) async throws -> Atlas {
        try await run {
            let prefix = String(format: "%04d-", year)
            let atlas = self.storedAtlas
            guard atlas.days.contains(where: { $0.day.hasPrefix(prefix) }) || atlas.traces.contains(where: { $0.day.hasPrefix(prefix) }) else {
                return Atlas()
            }
            return atlas
        }
    }

    /// Wears what is owned; a field left out stays as it is.
    public func setLook(_ choice: LookChoice) async throws -> InventoryState {
        try await run {
            var look = self.storedInventory.look ?? Look()
            let owned = self.storedInventory.cosmetics ?? []
            for kind in CosmeticKind.allCases {
                let wanted: String?
                switch kind {
                case .ink: wanted = choice.ink
                case .markerFrame: wanted = choice.markerFrame
                case .crestFrame: wanted = choice.crestFrame
                }
                guard let wanted else { continue }
                guard let item = owned.first(where: { CosmeticKind.bareId($0.itemId) == CosmeticKind.bareId(wanted) && $0.cosmeticKind == kind }) else {
                    throw APIError.server(code: APIErrorCode.notOwned, message: "You don't own that yet. Look for it at the stall.", status: 409)
                }
                look = look.with(kind, item.itemId)
            }
            self.storedInventory.look = look
            return self.storedInventory
        }
    }
}
