import XCTest
@testable import RoadsAndRunesCore

final class QuestWaysTests: XCTestCase {
    /// A RouteOption as the server sends it, with `questWay` spliced in (or left out).
    private func routeJSON(id: String, questWay: String?) -> String {
        let way = questWay.map { ", \"questWay\": \($0)" } ?? ""
        return """
        {
          "id": "\(id)", "label": "Adventure", "distanceMeters": 14200, "estimatedDurationSeconds": 3000,
          "elevationGainMeters": 40, "elevationLossMeters": 40, "highestPointMeters": 30, "maxGradientPercent": 4,
          "averageClimbGradientPercent": 2, "surface": {"paved": 1, "gravel": 0, "trail": 0, "unknown": 0},
          "cyclewayFraction": 0.5, "trafficExposure": 0.2, "newTerritoryFraction": 0.4, "questObjectiveCoverage": 1,
          "score": 0.8, "pois": [], "coordinates": [[-0.04, 51.49], [-0.041, 51.491]], "encodedPolyline": "abc",
          "instructions": [], "elevationSamples": [], "climbs": []\(way)
        }
        """
    }

    func testWaysFromTheContract() throws {
        let json = """
        {
          "ways": [
            {"kind": "LOOP", "name": "Loop", "summary": "Out to it and home another way", "bonus": null,
             "route": \(routeJSON(id: "55555555-5555-4555-8555-555555555555", questWay: "\"LOOP\""))},
            {"kind": "LONG_WAY", "name": "The long way", "summary": "A wider ring",
             "bonus": {"xp": 60, "ac": 10, "condition": "Ride the whole long way"},
             "route": \(routeJSON(id: "66666666-6666-4666-8666-666666666666", questWay: "\"LONG_WAY\""))},
            {"kind": "MOONLIT", "name": "By moonlight", "summary": "A kind this build has never heard of",
             "route": \(routeJSON(id: "77777777-7777-4777-8777-777777777777", questWay: "\"MOONLIT\""))}
          ],
          "chosenRouteId": "55555555-5555-4555-8555-555555555555",
          "notes": ["No one-way here: this quest asks you to come home"]
        }
        """
        let ways = try JSONCoding.decode(QuestWays.self, json: json)
        XCTAssertEqual(ways.ways.map(\.kind), [.loop, .longWay, .unknown])
        XCTAssertEqual(ways.ways.map(\.name), ["Loop", "The long way", "By moonlight"])
        XCTAssertNil(ways.ways[0].bonus, "bonus: null")
        XCTAssertNil(ways.ways[2].bonus, "bonus missing altogether")
        XCTAssertEqual(ways.ways[1].bonus, QuestWayBonus(xp: 60, ac: 10, condition: "Ride the whole long way"))
        XCTAssertEqual(ways.ways[0].route.questWay, .loop)
        XCTAssertEqual(ways.ways[2].route.questWay, .unknown)
        XCTAssertEqual(ways.ways[1].id, ways.ways[1].route.id)
        XCTAssertEqual(ways.chosenRouteId, UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        XCTAssertEqual(ways.notes, ["No one-way here: this quest asks you to come home"])
    }

    func testChosenRouteNullAndNoNotes() throws {
        let json = """
        {"ways": [{"kind": "ONE_WAY", "name": "One way", "summary": "Straight there", "bonus": null,
                   "route": \(routeJSON(id: "55555555-5555-4555-8555-555555555555", questWay: "\"ONE_WAY\""))}],
         "chosenRouteId": null}
        """
        let ways = try JSONCoding.decode(QuestWays.self, json: json)
        XCTAssertEqual(ways.ways.first?.kind, .oneWay)
        XCTAssertNil(ways.chosenRouteId)
        XCTAssertEqual(ways.notes, [])
    }

    func testRouteOptionWithoutQuestWay() throws {
        let missing = try JSONCoding.decode(RouteOption.self, json: routeJSON(id: "55555555-5555-4555-8555-555555555555", questWay: nil))
        XCTAssertNil(missing.questWay)
        let null = try JSONCoding.decode(RouteOption.self, json: routeJSON(id: "55555555-5555-4555-8555-555555555555", questWay: "null"))
        XCTAssertNil(null.questWay)
        let quiet = try JSONCoding.decode(RouteOption.self, json: routeJSON(id: "55555555-5555-4555-8555-555555555555", questWay: "\"QUIET\""))
        XCTAssertEqual(quiet.questWay, .quiet)
    }

    func testEndpoints() throws {
        let id = SampleData.questId
        let ways = Endpoints.questWays(id: id, from: Coordinate(latitude: 51.49, longitude: -0.04))
        XCTAssertEqual(ways.method, .get)
        XCTAssertEqual(ways.path, "/quests/\(id.uuidString)/ways")
        XCTAssertEqual(ways.query.map(\.name), ["latitude", "longitude"])
        XCTAssertEqual(ways.timeout, 90)
        XCTAssertTrue(Endpoints.questWays(id: id).query.isEmpty)

        let routeId = SampleData.routeId
        let choose = try Endpoints.chooseQuestWay(id: id, routeId: routeId)
        XCTAssertEqual(choose.method, .post)
        XCTAssertEqual(choose.path, "/quests/\(id.uuidString)/way")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(choose.body)) as? [String: String]
        XCTAssertEqual(body, ["routeId": routeId.uuidString])
    }

    func testMockOffersWaysAndHonoursTheChoice() async throws {
        let api = MockAPI()
        let route = try await api.questRoute(id: SampleData.questId)
        let ways = try await api.questWays(id: SampleData.questId, from: nil)
        XCTAssertEqual(ways.ways.first?.kind, .loop)
        XCTAssertEqual(ways.ways.first?.route.id, route.id)
        XCTAssertEqual(ways.chosenRouteId, route.id)
        XCTAssertEqual(Set(ways.ways.map(\.kind)), [.loop, .oneWay, .longWay, .newGround, .quiet])
        let oneWay = try XCTUnwrap(ways.ways.first { $0.kind == .oneWay })
        XCTAssertLessThan(oneWay.route.distanceMeters, route.distanceMeters)
        XCTAssertLessThan(oneWay.route.path.count, route.path.count)
        XCTAssertNotNil(ways.ways.first { $0.kind == .longWay }?.bonus)

        let quest = try await api.chooseQuestWay(id: SampleData.questId, routeId: oneWay.route.id)
        XCTAssertEqual(quest.suggestedRouteId, oneWay.route.id)
        XCTAssertEqual(quest.recommendedDistanceKm, oneWay.route.distanceMeters / 1000, accuracy: 0.05)
        let chosen = try await api.questRoute(id: SampleData.questId)
        XCTAssertEqual(chosen.id, oneWay.route.id, "the planner gets the chosen way")
        let again = try await api.questWays(id: SampleData.questId, from: nil)
        XCTAssertEqual(again.chosenRouteId, oneWay.route.id)
        XCTAssertEqual(again.ways.map(\.route.id), ways.ways.map(\.route.id), "the same ways while the rider stays put")

        do {
            _ = try await api.chooseQuestWay(id: SampleData.questId, routeId: UUID())
            XCTFail("a route that is not one of the quest's ways")
        } catch let error as APIError {
            XCTAssertEqual(error.errorCode, APIErrorCode.notFound)
        }
    }
}
