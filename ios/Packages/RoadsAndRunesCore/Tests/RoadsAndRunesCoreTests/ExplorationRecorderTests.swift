import XCTest
@testable import RoadsAndRunesCore

final class ExplorationRecorderTests: XCTestCase {
    private let indexing = FakeCellIndexing()
    private let t0 = SampleData.referenceDate
    /// Centre of a bucket: 51.490 / 0.002 = 25745 exactly.
    private let base = Coordinate(latitude: 51.490, longitude: -0.040)

    private func fix(_ coordinate: Coordinate, seconds: Double, accuracy: Double? = 5) -> LocationFix {
        LocationFix(coordinate: coordinate, timestamp: t0.addingTimeInterval(seconds), horizontalAccuracy: accuracy)
    }

    private func makeRecorder(known: Set<String> = [], batchSize: Int = 50) -> ExplorationRecorder {
        ExplorationRecorder(indexing: indexing, resolution: 9, knownCells: known, batchSize: batchSize, flushInterval: 60)
    }

    func testDedupesCellsAndTracksNewlyEntered() {
        let recorder = makeRecorder()
        let first = recorder.record(fix: fix(base, seconds: 0))
        XCTAssertEqual(first, ["25745_-20"])
        // 20 m north: same 0.002° bucket.
        let nearby = GeoMath.destination(from: base, bearingDegrees: 0, distanceMeters: 20)
        XCTAssertEqual(recorder.record(fix: fix(nearby, seconds: 10)), [])
        // 300 m north: next bucket.
        let next = GeoMath.destination(from: base, bearingDegrees: 0, distanceMeters: 300)
        XCTAssertEqual(recorder.record(fix: fix(next, seconds: 70)), ["25746_-20"])
        XCTAssertEqual(recorder.visitedCells, ["25745_-20", "25746_-20"])
        XCTAssertEqual(recorder.pendingUpload.count, 2)
        // Inaccurate fixes are ignored.
        let far = GeoMath.destination(from: base, bearingDegrees: 90, distanceMeters: 500)
        XCTAssertEqual(recorder.record(fix: fix(far, seconds: 80, accuracy: 90)), [])
        XCTAssertEqual(recorder.visitedCells.count, 2)
    }

    func testBatchFlushThresholds() {
        let recorder = makeRecorder()
        // 5 cells in the first 10 s: neither threshold reached.
        for i in 0..<5 {
            let c = GeoMath.destination(from: base, bearingDegrees: 90, distanceMeters: Double(i) * 200)
            recorder.record(fix: fix(c, seconds: Double(i) * 2))
        }
        XCTAssertEqual(recorder.pendingUpload.count, 5)
        XCTAssertNil(recorder.takePendingBatch(now: t0.addingTimeInterval(10)))
        // 60 s after the first fix the time threshold triggers.
        let timed = recorder.takePendingBatch(now: t0.addingTimeInterval(61))
        XCTAssertEqual(timed?.count, 5)
        XCTAssertTrue(recorder.pendingUpload.isEmpty)
        XCTAssertNil(recorder.takePendingBatch(now: t0.addingTimeInterval(62)))

        // 50 new cells trigger the count threshold regardless of time.
        for i in 0..<50 {
            let c = GeoMath.destination(from: base, bearingDegrees: 0, distanceMeters: 300 + Double(i) * 230)
            recorder.record(fix: fix(c, seconds: 70 + Double(i)))
        }
        XCTAssertEqual(recorder.pendingUpload.count, 50)
        let sized = recorder.takePendingBatch(now: t0.addingTimeInterval(65))
        XCTAssertEqual(sized?.count, 50)
        recorder.markUploaded(sized ?? [])
        XCTAssertEqual(recorder.uploadedCells.count, 50)

        // Force returns whatever is pending; requeue puts a failed batch back.
        recorder.record(fix: fix(GeoMath.destination(from: base, bearingDegrees: 180, distanceMeters: 300), seconds: 130))
        let forced = recorder.takePendingBatch(now: t0.addingTimeInterval(131), force: true)
        XCTAssertEqual(forced?.count, 1)
        recorder.requeue(forced ?? [])
        XCTAssertEqual(recorder.pendingUpload.count, 1)
    }

    func testCellBecomesExploredAfter400Metres() {
        let recorder = makeRecorder()
        let south = GeoMath.destination(from: base, bearingDegrees: 180, distanceMeters: 80)
        let north = GeoMath.destination(from: base, bearingDegrees: 0, distanceMeters: 80)
        let cell = indexing.cell(latitude: base.latitude, longitude: base.longitude, resolution: 9)
        XCTAssertEqual(indexing.cell(latitude: south.latitude, longitude: south.longitude, resolution: 9), cell)
        XCTAssertEqual(indexing.cell(latitude: north.latitude, longitude: north.longitude, resolution: 9), cell)

        recorder.record(fix: fix(south, seconds: 0))
        XCTAssertEqual(recorder.localState(for: cell), .visited)
        var time = 0.0
        var position = south
        var rode = 0.0
        while rode < 399 {
            position = (position == south) ? north : south
            time += 40
            recorder.record(fix: fix(position, seconds: time))
            rode += 160
        }
        // 3 legs = 480 m inside the cell.
        XCTAssertEqual(recorder.distance(in: cell), 480, accuracy: 1)
        XCTAssertEqual(recorder.localState(for: cell), .explored)
        XCTAssertEqual(recorder.localStates[cell], .explored)
        XCTAssertEqual(recorder.localState(for: "nowhere"), .unseen)
    }

    func testNewTerritoryExcludesKnownCells() {
        let homeCell = indexing.cell(latitude: base.latitude, longitude: base.longitude, resolution: 9)
        let recorder = makeRecorder(known: [homeCell])
        recorder.record(fix: fix(base, seconds: 0))
        let stillHome = GeoMath.destination(from: base, bearingDegrees: 0, distanceMeters: 60)
        recorder.record(fix: fix(stillHome, seconds: 20))
        XCTAssertEqual(recorder.newTerritoryMeters, 0)
        XCTAssertEqual(recorder.newCellCount, 0)
        XCTAssertEqual(recorder.localState(for: homeCell), .visited)

        let away = GeoMath.destination(from: base, bearingDegrees: 0, distanceMeters: 300)
        recorder.record(fix: fix(away, seconds: 80))
        XCTAssertEqual(recorder.newTerritoryMeters, 240, accuracy: 1)
        XCTAssertEqual(recorder.newCellCount, 1)
        // Implausible jump is not attributed to any cell.
        let teleport = GeoMath.destination(from: base, bearingDegrees: 0, distanceMeters: 5000)
        recorder.record(fix: fix(teleport, seconds: 81))
        XCTAssertEqual(recorder.newTerritoryMeters, 240, accuracy: 1)
    }

    func testFogGridMergesServerAndLocalState() {
        let recorder = makeRecorder()
        recorder.record(fix: fix(base, seconds: 0))
        let cell = indexing.cell(latitude: base.latitude, longitude: base.longitude, resolution: 9)
        let server = [
            ExplorationCell(h3: cell, state: .explored, firstVisitedAt: t0),
            ExplorationCell(h3: "25740_-20", state: .discovered),
        ]
        let grid = FogGrid(indexing: indexing, revealNeighbours: true)
        let rendered = grid.render(serverCells: server, recorder: recorder)
        let byId = Dictionary(uniqueKeysWithValues: rendered.map { ($0.h3, $0) })
        // Server EXPLORED beats local VISITED.
        XCTAssertEqual(byId[cell]?.state, .explored)
        XCTAssertEqual(byId[cell]?.polygon.count, 4)
        XCTAssertEqual(byId["25740_-20"]?.state, .discovered)
        // Neighbours of visited cells are revealed as DISCOVERED.
        XCTAssertEqual(byId["25746_-20"]?.state, .discovered)
        XCTAssertEqual(rendered.count, 2 + 8)

        let noReveal = FogGrid(indexing: indexing, revealNeighbours: false)
        XCTAssertEqual(noReveal.render(serverCells: server, localStates: [:]).count, 2)
    }
}
