import XCTest
@testable import RoadsAndRunesCore

final class MockAPITests: XCTestCase {
    func testQuestLifecycle() async throws {
        let api = MockAPI()
        let quests = try await api.quests(near: SampleData.origin)
        XCTAssertEqual(quests.items.count, 1)
        let generated = try await api.generateQuests(QuestGenerateRequest(latitude: 51.5, longitude: -0.03, count: 3))
        XCTAssertEqual(generated.items.count, 3)

        let quest = try await api.acceptQuest(id: SampleData.questId)
        XCTAssertEqual(quest.status, .accepted)
        let ride = try await api.createRide(RideCreate(clientRideId: UUID(), startedAt: Date(), questId: quest.id, routeId: SampleData.routeId))
        let started = try await api.startQuest(id: quest.id, rideId: ride.id)
        XCTAssertEqual(started.status, .active)

        do {
            _ = try await api.acceptQuest(id: quest.id)
            XCTFail("expected an invalid transition")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.questInvalidTransition)
        }

        let progressed = try await api.reportQuestProgress(id: quest.id, events: [ObjectiveEvent(objectiveId: SampleData.objectiveVisitId, occurredAt: Date(), coordinate: SampleData.origin)])
        XCTAssertEqual(progressed.objectives.first?.status, .completed)

        let completion = try await api.completeQuest(id: quest.id, rideId: ride.id)
        XCTAssertEqual(completion.quest.status, .completed)
        XCTAssertGreaterThan(completion.xpAwarded, 0)
    }

    func testRideCompletionAndSummaryPolling() async throws {
        let api = MockAPI()
        api.summaryPollsBeforeReady = 2
        let clientId = UUID()
        let ride = try await api.createRide(RideCreate(clientRideId: clientId, startedAt: SampleData.referenceDate))
        let again = try await api.createRide(RideCreate(clientRideId: clientId, startedAt: SampleData.referenceDate))
        XCTAssertEqual(ride.id, again.id, "createRide is idempotent on clientRideId")

        _ = try await api.uploadRidePoints(id: ride.id, RidePointsBatch(points: [RidePoint(latitude: 51.49, longitude: -0.04, timestamp: SampleData.referenceDate)]))
        _ = try await api.uploadRideExploration(id: ride.id, RideCellsBatch(cellsVisited: ["89194ad32cfffff"]))
        let response = try await api.completeRide(id: ride.id, RideComplete(endedAt: SampleData.referenceDate.addingTimeInterval(600), distanceMeters: 2400, durationSeconds: 600, movingSeconds: 580, elevationGainMeters: 24))
        XCTAssertEqual(response.processing, "QUEUED")
        XCTAssertEqual(response.ride.status, .processing)

        let first = try await api.rideSummary(id: ride.id)
        XCTAssertNil(first)
        let second = try await api.rideSummary(id: ride.id)
        XCTAssertNil(second)
        let summary = try await api.rideSummary(id: ride.id)
        XCTAssertEqual(summary?.ride.status, .processed)
        XCTAssertEqual(summary?.ride.distanceMeters, 2400)

        let world = try await api.world(center: SampleData.origin, radiusMeters: 5000)
        XCTAssertTrue(world.cells.contains { $0.h3 == "89194ad32cfffff" })
        let adventures = try await api.adventures()
        XCTAssertTrue(adventures.items.contains { $0.ride.id == ride.id })
    }

    func testFailNextAndExportURL() async throws {
        let api = MockAPI()
        api.failNext = .server(code: APIErrorCode.rateLimited, message: "Slow down", status: 429)
        do {
            _ = try await api.me()
            XCTFail("expected failure")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.rateLimited)
        }
        _ = try await api.me()
        let url = api.rideExportURL(id: SampleData.rideId, format: .gpx)
        XCTAssertTrue(url.absoluteString.hasSuffix("/rides/\(SampleData.rideId.uuidString)/export?format=gpx"))
    }

    func testAQuestRouteStartsWhereThePlayerIs() async throws {
        let api = MockAPI()
        let home = try await api.questRoute(id: SampleData.questId, from: SampleData.origin)
        let acrossTheRoad = GeoMath.destination(from: SampleData.origin, bearingDegrees: 90, distanceMeters: 80)
        let again = try await api.questRoute(id: SampleData.questId, from: acrossTheRoad)
        XCTAssertEqual(again.id, home.id)

        let elsewhere = GeoMath.destination(from: SampleData.origin, bearingDegrees: 300, distanceMeters: 3000)
        let moved = try await api.questRoute(id: SampleData.questId, from: elsewhere)
        XCTAssertNotEqual(moved.id, home.id)
        XCTAssertLessThan(GeoMath.distance(try XCTUnwrap(moved.path.first), elsewhere), 1)
        let quest = try await api.quest(id: SampleData.questId)
        XCTAssertEqual(quest.suggestedRouteId, moved.id)
        XCTAssertLessThan(GeoMath.distance(quest.origin, elsewhere), 1)
    }

    func testARerouteStartsAtTheRiderAndEndsWhereTheRouteDid() async throws {
        let api = MockAPI()
        let astray = GeoMath.destination(from: SampleData.origin, bearingDegrees: 0, distanceMeters: 900)
        let request = RerouteRequest(origin: astray, progressMeters: 420, completedObjectiveIds: [SampleData.objectiveVisitId])
        let route = try await api.reroute(routeId: SampleData.routeId, request)
        XCTAssertNotEqual(route.id, SampleData.routeId)
        XCTAssertEqual(route.path.first, astray)
        XCTAssertEqual(route.path.last, SampleData.sampleRoute.path.last)
        XCTAssertEqual(api.rerouteRequests, [request])

        api.rerouteFailure = .server(code: APIErrorCode.routeGenerationFailed, message: "No way back could be found from here", status: 502)
        do {
            _ = try await api.reroute(routeId: SampleData.routeId, request)
            XCTFail("expected the planner to be unreachable")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.routeGenerationFailed)
        }
        XCTAssertEqual(api.rerouteRequests.count, 2)
    }

    func testAChestOpensFromBesideItAndNotFromAcrossTheRoad() async throws {
        let api = MockAPI()
        let chest = SampleData.sampleChest
        let before = try await api.wallet().balance
        let far = GeoMath.destination(from: chest.coordinate, bearingDegrees: 90, distanceMeters: 200)
        do {
            _ = try await api.claimWorldObject(id: chest.id, WorldObjectClaimRequest(latitude: far.latitude, longitude: far.longitude, horizontalAccuracyMeters: 8))
            XCTFail("expected it to be out of reach")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.objectOutOfRange)
        }

        let beside = GeoMath.destination(from: chest.coordinate, bearingDegrees: 90, distanceMeters: 30)
        XCTAssertTrue(chest.isWithinReach(of: beside))
        XCTAssertFalse(chest.isWithinReach(of: far))
        let claim = try await api.claimWorldObject(id: chest.id, WorldObjectClaimRequest(latitude: beside.latitude, longitude: beside.longitude, horizontalAccuracyMeters: 8))
        XCTAssertEqual(claim.object.status, .claimed)
        XCTAssertEqual(claim.acAwarded, chest.rewardAC)
        XCTAssertEqual(claim.walletBalance, before + chest.rewardAC)
        let stillThere = try await api.worldObjects(near: chest.coordinate, radiusMeters: 500).map(\.id)
        XCTAssertFalse(stillThere.contains(chest.id))

        do {
            _ = try await api.claimWorldObject(id: chest.id, WorldObjectClaimRequest(latitude: beside.latitude, longitude: beside.longitude))
            XCTFail("expected it to be gone")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.objectGone)
        }
        // A monster is beaten on the move, not picked up.
        XCTAssertNil(SampleData.sampleMonster.reachMeters)
        XCTAssertFalse(SampleData.sampleMonster.isWithinReach(of: SampleData.sampleMonster.coordinate))
    }

    func testEndpointPaths() throws {
        let questRoute = Endpoints.questRoute(id: SampleData.questId, from: SampleData.origin)
        XCTAssertEqual(questRoute.path, "/quests/\(SampleData.questId.uuidString)/route")
        XCTAssertEqual(questRoute.query.map { $0.name }, ["latitude", "longitude"])
        XCTAssertTrue(Endpoints.questRoute(id: SampleData.questId).query.isEmpty)
        let reroute = try Endpoints.reroute(routeId: SampleData.routeId, RerouteRequest(origin: SampleData.origin))
        XCTAssertEqual(reroute.method, .post)
        XCTAssertEqual(reroute.path, "/routes/\(SampleData.routeId.uuidString)/reroute")
        XCTAssertLessThanOrEqual(reroute.timeout ?? 60, 30, "a rider off the route is not kept waiting like a planner is")
        let claim = try Endpoints.claimWorldObject(id: SampleData.sampleChest.id, WorldObjectClaimRequest(latitude: 51.49, longitude: -0.04))
        XCTAssertEqual(claim.path, "/world/objects/\(SampleData.sampleChest.id.uuidString)/claim")

        let endpoint = Endpoints.quests(near: SampleData.origin, status: .available, limit: 10, cursor: "abc")
        XCTAssertEqual(endpoint.path, "/quests")
        XCTAssertEqual(endpoint.query.map { $0.name }, ["latitude", "longitude", "status", "limit", "cursor"])
        XCTAssertEqual(endpoint.query[0].value, "51.49")
        let body = try Endpoints.startQuest(id: SampleData.questId, rideId: nil)
        XCTAssertEqual(body.method, .post)
        XCTAssertEqual(String(decoding: body.body ?? Data(), as: UTF8.self), "{}")
        XCTAssertFalse(Endpoints.health().requiresAuth)
        XCTAssertTrue(Endpoints.me().requiresAuth)
    }
}
