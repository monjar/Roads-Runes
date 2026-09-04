import Foundation

/// A cell ready for map rendering.
public struct CellRender: Hashable, Identifiable, Sendable {
    public var h3: String
    public var state: CellState
    public var polygon: [Coordinate]

    public var id: String { h3 }

    public init(h3: String, state: CellState, polygon: [Coordinate]) {
        self.h3 = h3
        self.state = state
        self.polygon = polygon
    }
}

/// Merges server exploration state with local ride progress into renderable
/// fog-of-war cells. A cell never regresses to a lower state.
public struct FogGrid: Sendable {
    public let indexing: CellIndexing
    /// When true, neighbours of visited cells that have no state become DISCOVERED.
    public var revealNeighbours: Bool

    public init(indexing: CellIndexing, revealNeighbours: Bool = true) {
        self.indexing = indexing
        self.revealNeighbours = revealNeighbours
    }

    public func mergedStates(serverCells: [ExplorationCell], localStates: [String: CellState]) -> [String: CellState] {
        var states: [String: CellState] = [:]
        for cell in serverCells {
            merge(cell.h3, cell.state, into: &states)
        }
        for (h3, state) in localStates {
            merge(h3, state, into: &states)
        }
        if revealNeighbours {
            let visited = states.filter { $0.value.rank >= CellState.visited.rank }.map { $0.key }
            for h3 in visited {
                for neighbour in indexing.neighbours(of: h3) where states[neighbour] == nil {
                    states[neighbour] = .discovered
                }
            }
        }
        return states
    }

    public func render(serverCells: [ExplorationCell], localStates: [String: CellState]) -> [CellRender] {
        let states = mergedStates(serverCells: serverCells, localStates: localStates)
        return states
            .filter { $0.value != .unseen && $0.value != .unknown }
            .map { CellRender(h3: $0.key, state: $0.value, polygon: indexing.boundary(of: $0.key)) }
            .sorted { $0.h3 < $1.h3 }
    }

    public func render(serverCells: [ExplorationCell], recorder: ExplorationRecorder) -> [CellRender] {
        render(serverCells: serverCells, localStates: recorder.localStates)
    }

    private func merge(_ h3: String, _ state: CellState, into states: inout [String: CellState]) {
        if let existing = states[h3], existing.rank >= state.rank { return }
        states[h3] = state
    }
}
