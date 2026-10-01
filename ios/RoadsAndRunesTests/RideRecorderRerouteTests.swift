import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunes

/// Leaving the route: a new one from where the rider is, the way back when there
/// is none to be had, and nothing adopted that the rider no longer wants.
@MainActor
final class RideRecorderRerouteTests: XCTestCase {
    private var api: MockAPI!
    private var container: AppContainer!
    private var recorder: RideRecorder { container.rideRecorder }
    private var clock: TimeInterval = 0

    override func setUp() async throws {
        api = MockAPI()
        container = AppContainer(api: api, inMemory: true)
        clock = 0
    }

    override func tearDown() async throws {
        container.rideRecorder.discard()
        container = nil
        api = nil
    }

    /// A fix at `coordinate`, `seconds` after the one before it.
    private func ride(to coordinate: Coordinate, after seconds: TimeInterval = 3) {
        clock += seconds
        recorder.handle(fix: LocationFix(coordinate: coordinate, timestamp: SampleData.referenceDate.addingTimeInterval(clock), altitude: 10, horizontalAccuracy: 5, speed: 5))
    }

    private func eventually(_ what: String, timeout: TimeInterval = 4, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    /// On the route for its first three points, then `meters` west of it, outside the loop.
    private func startAndLeave(by meters: Double = 250) async throws -> (package: RoutePackage, astray: Coordinate) {
        let package = try await api.routePackage(id: SampleData.routeId)
        await recorder.start(package: package, quest: package.quest, bikeId: nil)
        let path = package.route.path
        for point in path.prefix(3) { ride(to: point) }
        XCTAssertEqual(recorder.state, .active)
        let astray = GeoMath.destination(from: path[2], bearingDegrees: 270, distanceMeters: meters)
        for _ in 0..<RouteProgressTracker.offRouteConsecutiveUpdates { ride(to: astray) }
        return (package, astray)
    }

    func testLeavingTheRouteBringsANewOneFromWhereTheRiderIs() async throws {
        let (package, astray) = try await startAndLeave()
        // Plainly somewhere else: asked for at once, not after half a minute.
        XCTAssertEqual(recorder.state, .rerouting)
        XCTAssertEqual(recorder.rejoin?.compass, "east")
        XCTAssertEqual(recorder.rejoin?.distanceMeters ?? 0, 250, accuracy: 5)

        await eventually("a new route was taken") { recorder.state == .active }
        XCTAssertEqual(api.rerouteRequests.count, 1)
        let request = try XCTUnwrap(api.rerouteRequests.first)
        XCTAssertEqual(request.origin, astray)
        // As far as they had got before leaving: two sides of 120 m, and no further.
        XCTAssertEqual(request.progressMeters, 240, accuracy: 5)
        let route = try XCTUnwrap(recorder.package?.route)
        XCTAssertNotEqual(route.id, package.route.id)
        XCTAssertEqual(route.path.first, astray)
        XCTAssertEqual(route.path.last, package.route.path.last)
        XCTAssertEqual(recorder.package?.quest?.id, package.quest?.id)
        XCTAssertNil(recorder.rejoin)
        XCTAssertNil(recorder.rerouteError)
        XCTAssertTrue(recorder.recentReroute)
        XCTAssertFalse(recorder.isRerouting)
        XCTAssertNotNil(recorder.progress?.nextInstruction, "the new route has something to say at once")

        // Riding the new route is being on the route.
        ride(to: route.path[1])
        ride(to: route.path[2])
        XCTAssertEqual(recorder.state, .active)
        XCTAssertEqual(api.rerouteRequests.count, 1)
    }

    func testADriftIsNotAnEmergency() async throws {
        // Sixty metres off: off the route, but perhaps only cutting a corner.
        _ = try await startAndLeave(by: 60)
        XCTAssertEqual(recorder.state, .offRoute)
        XCTAssertTrue(api.rerouteRequests.isEmpty)
        let astray = try XCTUnwrap(recorder.lastFix?.coordinate)
        ride(to: astray, after: RerouteAdvisor.offRouteDelaySeconds)
        XCTAssertEqual(recorder.state, .rerouting)
        await eventually("a new route was taken") { recorder.state == .active }
        XCTAssertEqual(api.rerouteRequests.count, 1)
    }

    func testWithNoNewRouteToBeHadTheWayBackIsStillShown() async throws {
        api.rerouteFailure = .server(code: APIErrorCode.routeGenerationFailed, message: "No way back could be found from here", status: 502)
        let (package, astray) = try await startAndLeave()
        await eventually("the failure came back") { recorder.rerouteError != nil }
        // Not stuck "rerouting", and not left with nothing: which way, and how far.
        XCTAssertEqual(recorder.state, .offRoute)
        XCTAssertFalse(recorder.isRerouting)
        XCTAssertEqual(recorder.package?.route.id, package.route.id)
        XCTAssertEqual(recorder.rejoin?.compass, "east")
        XCTAssertEqual(api.rerouteRequests.count, 1)

        // It is asked for again, but not on every fix.
        ride(to: astray, after: 5)
        ride(to: astray, after: 5)
        XCTAssertEqual(api.rerouteRequests.count, 1)
        ride(to: astray, after: RerouteAdvisor.waitSeconds(afterFailures: 1))
        await eventually("a second try") { api.rerouteRequests.count == 2 }
        await eventually("which failed too") { recorder.state == .offRoute }

        // The planner comes back, and the rider does not wait for the clock.
        api.rerouteFailure = nil
        recorder.rerouteNow()
        XCTAssertEqual(recorder.state, .rerouting)
        await eventually("a new route was taken") { recorder.state == .active }
        XCTAssertEqual(api.rerouteRequests.count, 3)
        XCTAssertNil(recorder.rerouteError)
    }

    func testComingBackToTheRouteDropsTheOneOnItsWay() async throws {
        api.latency = 0.4
        let package = try await api.routePackage(id: SampleData.routeId)
        api.latency = 0
        await recorder.start(package: package, quest: package.quest, bikeId: nil)
        let path = package.route.path
        for point in path.prefix(3) { ride(to: point) }
        api.latency = 0.4
        let astray = GeoMath.destination(from: path[2], bearingDegrees: 270, distanceMeters: 250)
        for _ in 0..<3 { ride(to: astray) }
        XCTAssertEqual(recorder.state, .rerouting)

        // Back on it before the answer comes.
        ride(to: path[3])
        XCTAssertEqual(recorder.state, .active)
        XCTAssertFalse(recorder.isRerouting)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(recorder.package?.route.id, package.route.id, "a route nobody wants any more was taken anyway")
        XCTAssertEqual(recorder.state, .active)
        XCTAssertFalse(recorder.recentReroute)
    }

    func testARouteForWhereTheRiderWasIsAskedForAgain() async throws {
        let (_, astray) = try await startAndLeave(by: 60)
        api.latency = 0.3
        ride(to: astray, after: RerouteAdvisor.offRouteDelaySeconds)
        XCTAssertEqual(recorder.state, .rerouting)
        // They kept going while it was drawn: four hundred metres on by the time it arrives.
        let further = GeoMath.destination(from: astray, bearingDegrees: 0, distanceMeters: 400)
        ride(to: further)
        await eventually("asked again from where they are now") { api.rerouteRequests.count == 2 }
        XCTAssertEqual(api.rerouteRequests.last?.origin, further)
        await eventually("and that one taken") { recorder.state == .active }
        XCTAssertEqual(recorder.package?.route.path.first, further)
    }

    func testWhatIsAlreadyDoneIsSaidSoTheRouteDoesNotGoBackToIt() async throws {
        let package = try await api.routePackage(id: SampleData.routeId)
        let quest = try XCTUnwrap(package.quest)
        await recorder.start(package: package, quest: quest, bikeId: nil)
        let objective = try XCTUnwrap(quest.objectives.first { $0.coordinate != nil && ($0.objectiveType == .visitLocation || $0.objectiveType == .visitPOI) })
        let target = try XCTUnwrap(objective.coordinate)
        ride(to: package.route.path[0])
        ride(to: target)
        ride(to: target)
        XCTAssertTrue(recorder.completedObjectiveIDs.contains(objective.id))
        let astray = GeoMath.destination(from: target, bearingDegrees: 270, distanceMeters: 2000)
        for _ in 0..<3 { ride(to: astray) }
        await eventually("a reroute was asked for") { !api.rerouteRequests.isEmpty }
        XCTAssertTrue(api.rerouteRequests.last?.completedObjectiveIds.contains(objective.id) ?? false)
    }

    func testEndingARideWhileANewRouteIsOnItsWayEndsIt() async throws {
        api.latency = 0
        _ = try await startAndLeave(by: 60)
        api.latency = 0.3
        let astray = try XCTUnwrap(recorder.lastFix?.coordinate)
        ride(to: astray, after: RerouteAdvisor.offRouteDelaySeconds)
        XCTAssertEqual(recorder.state, .rerouting)
        api.latency = 0
        await recorder.finish()
        XCTAssertEqual(recorder.state, .completed)
        XCTAssertFalse(recorder.isActive)
        XCTAssertFalse(recorder.isRerouting)
    }
}
