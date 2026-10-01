import XCTest
@testable import RoadsAndRunesCore

final class RerouteAdvisorTests: XCTestCase {
    private let t0 = SampleData.referenceDate

    func testADriftIsGivenAMomentAndThenRerouted() {
        var advisor = RerouteAdvisor()
        XCTAssertFalse(advisor.shouldReroute(now: t0), "on the route there is nothing to ask for")
        advisor.observe(isOffRoute: true, at: t0)
        XCTAssertFalse(advisor.shouldReroute(now: t0.addingTimeInterval(3), crossTrackMeters: 60))
        XCTAssertTrue(advisor.shouldReroute(now: t0.addingTimeInterval(RerouteAdvisor.offRouteDelaySeconds), crossTrackMeters: 60))

        // Back on the route before then: nothing is asked for, and the clock starts again next time.
        advisor.observe(isOffRoute: false, at: t0.addingTimeInterval(5))
        advisor.observe(isOffRoute: true, at: t0.addingTimeInterval(6))
        XCTAssertFalse(advisor.shouldReroute(now: t0.addingTimeInterval(9), crossTrackMeters: 60))
    }

    func testSomeonePlainlyElsewhereIsNotKeptWaiting() {
        var advisor = RerouteAdvisor()
        advisor.observe(isOffRoute: true, at: t0)
        XCTAssertTrue(advisor.shouldReroute(now: t0, crossTrackMeters: 1500))
    }

    func testRequestsAreSpacedAndFailuresBackOff() {
        var advisor = RerouteAdvisor()
        advisor.observe(isOffRoute: true, at: t0)
        advisor.markRerouted(at: t0.addingTimeInterval(10))
        XCTAssertFalse(advisor.shouldReroute(now: t0.addingTimeInterval(20), crossTrackMeters: 500))
        XCTAssertTrue(advisor.shouldReroute(now: t0.addingTimeInterval(25), crossTrackMeters: 500))

        advisor.markFailed()
        XCTAssertFalse(advisor.shouldReroute(now: t0.addingTimeInterval(25), crossTrackMeters: 500))
        XCTAssertTrue(advisor.shouldReroute(now: t0.addingTimeInterval(40), crossTrackMeters: 500))
        advisor.markFailed()
        advisor.markFailed()
        advisor.markFailed()
        XCTAssertEqual(RerouteAdvisor.waitSeconds(afterFailures: advisor.consecutiveFailures), RerouteAdvisor.maxBackoffSeconds)
        XCTAssertFalse(advisor.shouldReroute(now: t0.addingTimeInterval(60), crossTrackMeters: 500))
        XCTAssertTrue(advisor.shouldReroute(now: t0.addingTimeInterval(70), crossTrackMeters: 500))

        // The rider asked for it themselves: no waiting.
        advisor.clearThrottle()
        XCTAssertTrue(advisor.shouldReroute(now: t0.addingTimeInterval(11), crossTrackMeters: 500))

        // A route taken clears the slate.
        advisor.markSucceeded()
        XCTAssertEqual(advisor.consecutiveFailures, 0)
        XCTAssertNil(advisor.offRouteSince)
    }

    func testTheWayBackHasADistanceAndADirection() {
        let here = SampleData.origin
        let guide = RejoinGuide(from: here, to: GeoMath.destination(from: here, bearingDegrees: 47, distanceMeters: 420))
        XCTAssertEqual(guide.distanceMeters, 420, accuracy: 1)
        XCTAssertEqual(guide.compass, "north-east")
        XCTAssertEqual(RejoinGuide.compassPoint(for: 350), "north")
        XCTAssertEqual(RejoinGuide.compassPoint(for: 10), "north")
        XCTAssertEqual(RejoinGuide.compassPoint(for: 180), "south")
        XCTAssertEqual(RejoinGuide.compassPoint(for: 292), "west")
        XCTAssertEqual(RejoinGuide.compassPoint(for: -45), "north-west")
    }
}
