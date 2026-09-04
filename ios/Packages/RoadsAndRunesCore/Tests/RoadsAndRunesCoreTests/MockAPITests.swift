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

    func testEndpointPaths() throws {
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
