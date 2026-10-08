import Foundation

// Legends, lairs and treasure maps (0.8.0): the server's rules, small enough to
// hold in memory. Called inside `run`, so under the lock.
extension MockAPI {
    public func legends() async throws -> LegendsState {
        try await run {
            var state = self.storedLegends
            state.awake?.journeys = nil
            return state
        }
    }

    public func legend(id: UUID) async throws -> Legend {
        try await run {
            guard let legend = self.storedLegends.awake, legend.id == id else { throw self.notFound("Legend") }
            return legend
        }
    }

    /// Its one free move: somewhere else about as far, once.
    public func moveLegend(id: UUID) async throws -> Legend {
        try await run {
            guard var legend = self.storedLegends.awake, legend.id == id else { throw self.notFound("Legend") }
            guard !legend.moved else {
                throw self.conflict(APIErrorCode.alreadyMoved, "You've moved it once already. It stays where it is now.")
            }
            let moved = GeoMath.destination(from: legend.coordinate, bearingDegrees: 120, distanceMeters: 1500)
            legend.latitude = moved.latitude
            legend.longitude = moved.longitude
            legend.anchorName = "Russia Dock Woodland"
            legend.moved = true
            self.storedLegends.awake = legend
            return legend
        }
    }

    public func treasureClues() async throws -> [TreasureClue] {
        try await run { self.storedClues }
    }

    /// A treasure map used where the player stands: one clue at a time, never a place.
    func useTreasureMap(_ request: ConsumableUseRequest) throws -> ConsumableUseResult {
        guard request.latitude != nil, request.longitude != nil else {
            throw APIError.server(code: APIErrorCode.validationError, message: "Where are you? Try again once your location is found.", status: 422)
        }
        guard storedClues.isEmpty else {
            throw conflict(APIErrorCode.oneAtATime, "You're already following a treasure map. Find that treasure first.")
        }
        _ = takeConsumable(ConsumableId.treasureMap)
        let clue = TreasureClue(treasureId: UUID(), clue: SampleData.sampleClue.clue, buriedAt: Date())
        storedClues = [clue]
        return ConsumableUseResult(inventory: storedInventory, clue: clue.clue, treasureId: clue.treasureId)
    }
}
