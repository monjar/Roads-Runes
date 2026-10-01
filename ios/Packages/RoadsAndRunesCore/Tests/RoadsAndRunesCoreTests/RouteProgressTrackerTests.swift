import XCTest
@testable import RoadsAndRunesCore

final class RouteProgressTrackerTests: XCTestCase {
    private let loop = SampleData.squareLoop(center: SampleData.origin, sideMeters: 600, pointsPerSide: 5)

    private func makeTracker() -> RouteProgressTracker {
        RouteProgressTracker(path: loop, instructions: SampleData.sampleInstructions)
    }

    /// The middle of segment `index`: unambiguously on it, where a vertex belongs to two.
    private func midpoint(_ index: Int) -> Coordinate {
        Coordinate(latitude: (loop[index].latitude + loop[index + 1].latitude) / 2, longitude: (loop[index].longitude + loop[index + 1].longitude) / 2)
    }

    /// Points along the path: every vertex plus the midpoint of every segment.
    private func ridePositions() -> [Coordinate] {
        var positions: [Coordinate] = []
        for index in 0..<(loop.count - 1) {
            let a = loop[index], b = loop[index + 1]
            positions.append(a)
            positions.append(Coordinate(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2))
        }
        positions.append(loop[loop.count - 1])
        return positions
    }

    func testProgressIncreasesMonotonicallyAlongLoop() {
        var tracker = makeTracker()
        var lastAlong = -1.0
        var lastSegment = -1
        for position in ridePositions() {
            let update = tracker.update(position: position)
            XCTAssertGreaterThanOrEqual(update.distanceAlongRoute, lastAlong)
            XCTAssertGreaterThanOrEqual(update.nearestSegmentIndex, lastSegment)
            XCTAssertLessThan(update.crossTrackDistance, 1)
            XCTAssertFalse(update.isOffRoute)
            lastAlong = update.distanceAlongRoute
            lastSegment = update.nearestSegmentIndex
        }
        XCTAssertEqual(lastAlong, tracker.totalDistance, accuracy: 1)
        XCTAssertEqual(tracker.lastUpdate?.fractionComplete ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(tracker.lastUpdate?.distanceRemaining ?? -1, 0, accuracy: 1)
    }

    func testLoopStartDoesNotJumpToFinish() {
        var tracker = makeTracker()
        // Start and finish share a coordinate: the first fix must match segment 0.
        let update = tracker.update(position: loop[0])
        XCTAssertEqual(update.nearestSegmentIndex, 0)
        XCTAssertEqual(update.distanceAlongRoute, 0, accuracy: 0.01)
        XCTAssertEqual(update.nextInstruction?.coordinateIndex, 5)
    }

    func testNextInstructionAdvances() {
        var tracker = makeTracker()
        let first = tracker.update(position: loop[2])
        XCTAssertEqual(first.nextInstruction?.coordinateIndex, 5)
        XCTAssertEqual(first.nextInstruction?.sign, .right)
        XCTAssertEqual(first.distanceToNextInstruction ?? 0, GeoMath.distance(loop[2], loop[5]), accuracy: 2)

        let atTurn = tracker.update(position: loop[5])
        // Standing on vertex 5 we are matched to segment 4 (fraction 1) or 5 (fraction 0).
        XCTAssertTrue(atTurn.nextInstruction?.coordinateIndex == 5 || atTurn.nextInstruction?.coordinateIndex == 10)

        let afterTurn = tracker.update(position: loop[7])
        XCTAssertEqual(afterTurn.nextInstruction?.coordinateIndex, 10)

        let nearEnd = tracker.update(position: loop[18])
        XCTAssertEqual(nearEnd.nextInstruction?.sign, .finish)
        XCTAssertEqual(nearEnd.nextInstruction?.coordinateIndex, 20)
    }

    func testOffRouteHysteresis() {
        var tracker = makeTracker()
        _ = tracker.update(position: loop[1])
        // 100 m west of the middle of segment 2 (outside the square).
        let anchor = Coordinate(latitude: (loop[2].latitude + loop[3].latitude) / 2, longitude: (loop[2].longitude + loop[3].longitude) / 2)
        let far = GeoMath.destination(from: anchor, bearingDegrees: 270, distanceMeters: 100)
        let one = tracker.update(position: far)
        XCTAssertFalse(one.isOffRoute)
        XCTAssertGreaterThan(one.crossTrackDistance, 40)
        let two = tracker.update(position: far)
        XCTAssertFalse(two.isOffRoute)
        let three = tracker.update(position: far)
        XCTAssertTrue(three.isOffRoute)
        XCTAssertTrue(tracker.isOffRoute)

        // 30 m off is inside the off threshold but not yet within the on threshold.
        let between = GeoMath.destination(from: anchor, bearingDegrees: 270, distanceMeters: 30)
        XCTAssertTrue(tracker.update(position: between).isOffRoute)

        let near = GeoMath.destination(from: anchor, bearingDegrees: 270, distanceMeters: 5)
        let back = tracker.update(position: near)
        XCTAssertFalse(back.isOffRoute)
        XCTAssertEqual(back.nearestSegmentIndex, 2)
    }

    func testFarFixesAreNotConsecutiveWhenInterrupted() {
        var tracker = makeTracker()
        let far = GeoMath.destination(from: loop[2], bearingDegrees: 270, distanceMeters: 100)
        _ = tracker.update(position: far)
        _ = tracker.update(position: far)
        _ = tracker.update(position: loop[2])
        _ = tracker.update(position: far)
        _ = tracker.update(position: far)
        XCTAssertFalse(tracker.isOffRoute)
        _ = tracker.update(position: far)
        XCTAssertTrue(tracker.isOffRoute)
    }

    /// A rider a kilometre away used to "progress": the match crept along the route to
    /// whatever was nearest, through turns they never took.
    func testNoProgressIsMadeOffTheRoute() {
        var tracker = makeTracker()
        let onRoute = tracker.update(position: midpoint(2))
        XCTAssertEqual(onRoute.nearestSegmentIndex, 2)

        // Ride away east, across the square and out the far side: nearer and nearer to
        // the later sides of the loop, never on them.
        var last = onRoute
        for meters in stride(from: 100.0, through: 500.0, by: 50) {
            last = tracker.update(position: GeoMath.destination(from: loop[2], bearingDegrees: 90, distanceMeters: meters))
        }
        XCTAssertTrue(last.isOffRoute)
        XCTAssertEqual(last.nearestSegmentIndex, 2)
        XCTAssertEqual(last.distanceAlongRoute, onRoute.distanceAlongRoute, accuracy: 0.5)
        XCTAssertEqual(last.nextInstruction?.coordinateIndex, 5)
        XCTAssertEqual(tracker.lastDistanceAlong, onRoute.distanceAlongRoute, accuracy: 0.5)
    }

    func testOffRouteSaysWhereToRejoin() {
        var tracker = makeTracker()
        _ = tracker.update(position: loop[1])
        // 300 m west of the west side, level with vertex 3: the way back is straight east to it.
        let astray = GeoMath.destination(from: loop[3], bearingDegrees: 270, distanceMeters: 300)
        var update = tracker.update(position: astray)
        for _ in 0..<3 { update = tracker.update(position: astray) }
        XCTAssertTrue(update.isOffRoute)
        XCTAssertEqual(update.crossTrackDistance, 300, accuracy: 3)
        XCTAssertLessThan(GeoMath.distance(update.snappedPosition, loop[3]), 3)

        // The part already ridden is not the way back: from beside the start, having got
        // as far as the north side, the nearest of what is left is what is offered.
        var later = makeTracker()
        _ = later.update(position: midpoint(7))
        let nearStart = GeoMath.destination(from: loop[0], bearingDegrees: 270, distanceMeters: 200)
        var back = later.update(position: nearStart)
        for _ in 0..<3 { back = later.update(position: nearStart) }
        XCTAssertTrue(back.isOffRoute)
        XCTAssertGreaterThan(GeoMath.distance(back.snappedPosition, loop[2]), 100)
        XCTAssertEqual(back.nearestSegmentIndex, 7)
    }

    func testTrackerFromRouteOption() {
        var tracker = RouteProgressTracker(route: SampleData.sampleRoute)
        XCTAssertEqual(tracker.segmentCount, 20)
        XCTAssertEqual(tracker.totalDistance, 2400, accuracy: 5)
        let update = tracker.update(position: SampleData.sampleLoop[10])
        XCTAssertEqual(update.fractionComplete, 0.5, accuracy: 0.01)
    }

    func testEmptyRouteIsSafe() {
        var tracker = RouteProgressTracker(path: [], instructions: [])
        let update = tracker.update(position: SampleData.origin)
        XCTAssertEqual(update.distanceRemaining, 0)
        XCTAssertNil(update.nextInstruction)
    }
}
