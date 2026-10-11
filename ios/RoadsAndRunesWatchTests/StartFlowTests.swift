import RoadsAndRunesCore
import XCTest
@testable import RoadsAndRunesWatch

/// Starting a journey from the wrist (0.7.3), with a stand-in for the phone.
@MainActor
final class StartFlowTests: XCTestCase {
    /// The phone as the Watch sees it: whether it is there, and what was sent to it.
    private final class FakeLink: PhoneLink {
        var isActivated = true
        var isReachable = true
        var sent: [[String: Any]] = []
        var queued: [[String: Any]] = []
        var errorHandlers: [(Error) -> Void] = []

        func send(_ message: [String: Any], errorHandler: ((Error) -> Void)?) {
            sent.append(message)
            if let errorHandler { errorHandlers.append(errorHandler) }
        }

        func queue(_ message: [String: Any]) {
            queued.append(message)
        }
    }

    private struct Unreachable: Error {}

    private func summary() -> WatchRouteSummary {
        WatchRouteSummary(questTitle: nil, instructions: [], objectives: [], totalDistanceMeters: 10_000, activity: "RUN")
    }

    func testAStartGoesToThePhoneAndThePlanEndsWhenTheRideComes() throws {
        let store = RideStore()
        let link = FakeLink()
        let phone = PhoneSessionService(store: store, link: link)
        // Whole seconds: the messages carry times to the second.
        let request = WatchStartRequest(kind: WatchStartRequest.loop, minutes: 40, activity: "RUN", requestedAt: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(phone.requestStart(request))
        XCTAssertTrue(store.isPlanning)
        XCTAssertTrue(link.queued.isEmpty, "a start is never queued for later")
        let sent = try XCTUnwrap(link.sent.first)
        XCTAssertEqual(WatchMessages.kind(of: sent), .startRequest)
        let asked = try WatchMessages.startRequest(from: sent)
        XCTAssertEqual(asked, request)
        XCTAssertEqual(asked.quickStart(defaultActivity: .ride, at: Date(timeIntervalSince1970: 1_790_000_030)), .loop(minutes: 40, activity: .run))

        // The phone started it: its route summary takes the Watch to the ride.
        phone.apply(PhoneSessionService.read(try WatchMessages.startResult(WatchStartResult(requestId: request.id, started: true))))
        XCTAssertTrue(store.isPlanning)
        phone.apply(PhoneSessionService.read(try WatchMessages.routeSummary(summary())))
        XCTAssertNil(store.planning)
        XCTAssertTrue(store.hasRoute)
        XCTAssertEqual(store.activity, .run)
    }

    func testThePhoneSayingNoShowsThatItCouldNotPlan() throws {
        let store = RideStore()
        let phone = PhoneSessionService(store: store, link: FakeLink())
        let request = WatchStartRequest.bounty(activity: .ride)
        phone.requestStart(request)
        phone.apply(PhoneSessionService.read(try WatchMessages.startResult(WatchStartResult(requestId: request.id, started: false))))
        XCTAssertTrue(store.planningFailed)
        XCTAssertFalse(store.hasRoute)
    }

    func testWithNoPhoneThereTheStartFailsAtOnce() {
        let store = RideStore()
        let link = FakeLink()
        link.isReachable = false
        let phone = PhoneSessionService(store: store, link: link)
        XCTAssertFalse(phone.requestStart(.quest(id: UUID())))
        XCTAssertTrue(store.planningFailed)
        XCTAssertTrue(link.sent.isEmpty)
        XCTAssertTrue(link.queued.isEmpty)
    }

    func testAMessageThatCannotGoFailsThePlan() async throws {
        let store = RideStore()
        let link = FakeLink()
        let phone = PhoneSessionService(store: store, link: link)
        let request = WatchStartRequest.sealed(minutes: 40)
        phone.requestStart(request)
        let failed = try XCTUnwrap(link.errorHandlers.first)
        failed(Unreachable())
        // The failure comes back on the main actor.
        for _ in 0..<20 where store.isPlanning { await Task.yield() }
        XCTAssertTrue(store.planningFailed)
    }

    func testNextUpComesInTheContextBesideTheRideAndAlone() throws {
        let store = RideStore()
        let phone = PhoneSessionService(store: store, link: FakeLink())
        let idle = WatchIdleInfo(streakDays: 5, streakActiveToday: true, bounty: .init(name: "Fen Troll", icon: "troll", distanceMeters: 1200),
                                 quests: [.init(id: UUID(), title: "Beyond the Water")], activity: "WALK",
                                 updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let context = try WatchMessages.context(ride: WatchMessages.routeSummary(summary()), idle: idle)
        phone.apply(PhoneSessionService.read(context))
        XCTAssertEqual(store.idle, idle)
        XCTAssertTrue(store.hasRoute, "the ride's message in the same context still arrives")

        let between = RideStore()
        let other = PhoneSessionService(store: between, link: FakeLink())
        other.apply(PhoneSessionService.read(try WatchMessages.context(ride: nil, idle: idle)))
        XCTAssertEqual(between.idle?.activityKind, .walk)
        XCTAssertFalse(between.hasRoute)
        // An older phone's context has no Next up: the idle face stays the 0.7.2 one.
        let older = RideStore()
        PhoneSessionService(store: older, link: FakeLink()).apply(PhoneSessionService.read(try WatchMessages.routeSummary(summary())))
        XCTAssertNil(older.idle)
    }

    func testTheComplicationIsToldOnlyWhenSomethingChanged() throws {
        let suite = "rr.tests.watch-face.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reloads = 0
        let face = ComplicationWriter(defaults: defaults) { reloads += 1 }
        let idle = WatchIdleInfo(streakDays: 2, updatedAt: Date(timeIntervalSince1970: 1_000))
        face.publish(idle: idle, quarry: nil)
        XCTAssertEqual(reloads, 1)
        face.publish(idle: idle, quarry: nil)
        XCTAssertEqual(reloads, 1, "nothing new")
        face.publish(idle: nil, quarry: WatchQuarry(name: "Bog Wraith", icon: "ghost"))
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(face.keptIdle(), idle, "no Next up given keeps the last")
        face.publish(idle: idle, quarry: nil)
        XCTAssertEqual(reloads, 3, "the journey over, the quarry goes")
    }

    // MARK: - Ride anywhere (0.9.2)

    /// A roam's summary has no turns and no line, only the world round the rider. It
    /// is still the sign that the journey started, and it is a free journey on the wrist.
    func testAnEmptySummaryIsARoamAndEndsThePlanning() throws {
        let store = RideStore()
        let phone = PhoneSessionService(store: store, link: FakeLink())
        phone.requestStart(WatchStartRequest.loop(minutes: 40, activity: .ride))
        XCTAssertTrue(store.isPlanning)
        let chest = WatchWorldMark(id: UUID(), kind: WatchWorldMark.chest, name: "Old chest", latitude: 51.49, longitude: -0.04)
        phone.apply(PhoneSessionService.read(try WatchMessages.routeSummary(.roaming(activity: .walk, worldMarks: [chest]))))
        XCTAssertNil(store.planning, "the journey has started")
        XCTAssertTrue(store.hasRoute)
        XCTAssertTrue(store.isRoaming)
        XCTAssertFalse(store.followsRoute)
        XCTAssertEqual(store.activity, .walk)
        XCTAssertEqual(store.worldMarks.map(\.id), [chest.id])
        XCTAssertNil(store.currentInstruction)
    }

    /// "Ride anywhere" on the wrist: a ROAM request goes to the phone, and the roam's
    /// summary takes the Watch to the ride.
    func testARoamAskedForOnTheWristGoesToTheRide() throws {
        let store = RideStore()
        let link = FakeLink()
        let phone = PhoneSessionService(store: store, link: link)
        var request = WatchStartRequest.roam(activity: .run)
        request.requestedAt = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(phone.requestStart(request))
        XCTAssertTrue(store.isPlanning)
        let asked = try WatchMessages.startRequest(from: try XCTUnwrap(link.sent.first))
        XCTAssertEqual(asked.kind, WatchStartRequest.roam)
        XCTAssertEqual(asked.activity, "RUN")
        phone.apply(PhoneSessionService.read(try WatchMessages.routeSummary(.roaming(activity: .run, worldMarks: []))))
        XCTAssertNil(store.planning)
        XCTAssertTrue(store.hasRoute && store.isRoaming, "the ride pages, as a free journey")

        // Next up offers it only when the phone says it can.
        store.apply(idle: WatchIdleInfo(streakDays: 1, updatedAt: Date(timeIntervalSince1970: 1_000), rideAnywhere: true))
        XCTAssertEqual(store.idle?.offersRideAnywhere, true)
        store.apply(idle: WatchIdleInfo(streakDays: 1, updatedAt: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(store.idle?.offersRideAnywhere, false)
    }

    /// A planned route's summary is no roam.
    func testAPlannedRouteIsNoRoam() {
        let planned = RideStore()
        planned.apply(summary: WatchRouteSummary(questTitle: nil, instructions: [], objectives: [], totalDistanceMeters: 10_000,
                                                 routeCoordinates: [[-0.04, 51.49], [-0.03, 51.5]]))
        XCTAssertTrue(planned.followsRoute)
        XCTAssertFalse(planned.isRoaming)
    }
}
