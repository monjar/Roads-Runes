import XCTest
@testable import RoadsAndRunesCore

final class ModelDecodingTests: XCTestCase {
    func testQuestFromAPIDocSample() throws {
        let json = """
        {
          "id": "44444444-4444-4444-8444-444444444444",
          "questType": "EXPLORE_REGION",
          "characterClass": "EXPLORER",
          "templateId": "EXPLORER_NEW_TERRITORY",
          "title": "Beyond the Water",
          "description": "...",
          "narrative": {"hook": "...", "completion": "..."},
          "difficulty": "MODERATE",
          "recommendedDistanceKm": 28,
          "estimatedDurationMinutes": 120,
          "baseXP": 350,
          "status": "AVAILABLE",
          "expiresAt": null,
          "storyQuestId": null,
          "origin": {"latitude": 51.49, "longitude": -0.04},
          "objectives": [{
            "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "objectiveType": "VISIT_LOCATION",
            "title": "Reach Old Station",
            "latitude": 51.49, "longitude": -0.04, "radiusMeters": 50,
            "targetMeters": null, "targetCells": null, "targetElevationMeters": null,
            "required": true, "order": 1,
            "completionRule": "INDIVIDUAL",
            "status": "PENDING",
            "completedAt": null,
            "progress": {"current": 0, "target": 1}
          }],
          "rewards": {"xp": 350, "items": [], "titles": []},
          "suggestedRouteId": null,
          "acceptedAt": null, "startedAt": null, "completedAt": null
        }
        """
        let quest = try JSONCoding.decode(Quest.self, json: json)
        XCTAssertEqual(quest.id, SampleData.questId)
        XCTAssertEqual(quest.characterClass, .explorer)
        XCTAssertEqual(quest.difficulty, .moderate)
        XCTAssertEqual(quest.status, .available)
        XCTAssertEqual(quest.origin.latitude, 51.49, accuracy: 1e-9)
        XCTAssertEqual(quest.objectives.count, 1)
        XCTAssertEqual(quest.objectives[0].objectiveType, .visitLocation)
        XCTAssertEqual(quest.objectives[0].radiusMeters, 50)
        XCTAssertNil(quest.objectives[0].targetMeters)
        XCTAssertEqual(quest.objectives[0].completionRule, .individual)
        XCTAssertEqual(quest.rewards.xp, 350)
        XCTAssertEqual(quest.narrative.hook, "...")
        XCTAssertNil(quest.createdAt)
    }

    func testObjectiveExtraCells() throws {
        let json = """
        {"id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "objectiveType": "VISIT_MULTIPLE_LOCATIONS", "title": "Three corners",
         "required": true, "order": 1, "completionRule": "INDIVIDUAL", "status": "PENDING",
         "progress": {"current": 0, "target": 2},
         "extra": {"cells": [{"h3": "a", "latitude": 51.5, "longitude": -0.1}, {"h3": "b", "latitude": 51.6, "longitude": -0.2}]}}
        """
        let objective = try JSONCoding.decode(Objective.self, json: json)
        let cells = ObjectiveTracker.cells(from: objective)
        XCTAssertEqual(cells.map { $0.h3 }, ["a", "b"])
        XCTAssertEqual(cells[1].coordinate.longitude, -0.2, accuracy: 1e-9)
    }

    func testRouteOptionFromAPIDocSample() throws {
        let json = """
        {
          "id": "55555555-5555-4555-8555-555555555555",
          "label": "Adventure",
          "distanceMeters": 31200,
          "estimatedDurationSeconds": 6900,
          "elevationGainMeters": 340, "elevationLossMeters": 335,
          "highestPointMeters": 120, "maxGradientPercent": 9.5, "averageClimbGradientPercent": 4.1,
          "longestClimb": {"startMeters": 12000, "lengthMeters": 1800, "gainMeters": 90, "averageGradientPercent": 5.0},
          "surface": {"paved": 0.7, "gravel": 0.25, "trail": 0.05, "unknown": 0.0},
          "cyclewayFraction": 0.55,
          "trafficExposure": 0.2,
          "newTerritoryFraction": 0.62,
          "questObjectiveCoverage": 1.0,
          "score": 0.81,
          "pois": [{"discoveryId": "88888888-8888-4888-8888-888888888888", "name": "The Crown", "category": "PUB", "latitude": 51.5, "longitude": -0.03,
                    "routePositionMeters": 24600, "detourMeters": 600, "detourSeconds": 180, "estimatedArrivalSeconds": 5400}],
          "coordinates": [[-0.04, 51.49], [-0.041, 51.491, 12.5]],
          "encodedPolyline": "abc",
          "instructions": [{"index": 0, "text": "Turn right onto Rotherhithe Street", "streetName": "Rotherhithe Street", "sign": "RIGHT",
                            "distanceMeters": 180, "durationSeconds": 40, "coordinateIndex": 12, "latitude": 51.5, "longitude": -0.04}],
          "elevationSamples": [{"distanceMeters": 0, "elevationMeters": 22}],
          "climbs": []
        }
        """
        let route = try JSONCoding.decode(RouteOption.self, json: json)
        XCTAssertEqual(route.label, "Adventure")
        XCTAssertEqual(route.longestClimb?.lengthMeters, 1800)
        XCTAssertEqual(route.surface.gravel, 0.25, accuracy: 1e-9)
        XCTAssertEqual(route.pois.first?.category, .pub)
        XCTAssertEqual(route.instructions.first?.sign, .right)
        XCTAssertEqual(route.path.count, 2)
        XCTAssertEqual(route.path[1].latitude, 51.491, accuracy: 1e-9)
        XCTAssertNil(route.engine)
    }

    func testRideAndAdventureSummary() throws {
        let rideJSON = """
        {
          "id": "66666666-6666-4666-8666-666666666666", "clientRideId": "77777777-7777-4777-8777-777777777777",
          "status": "PROCESSED",
          "startedAt": "2026-01-01T00:00:00Z", "endedAt": null,
          "distanceMeters": 32400, "durationSeconds": 7480, "movingSeconds": 7000,
          "elevationGainMeters": 340, "activeCalories": 876,
          "averageSpeedMps": 4.3, "maxSpeedMps": 11.2,
          "questId": null, "bikeId": null, "routeId": null,
          "visibility": "PRIVATE",
          "healthKitWorkoutId": null,
          "pointCount": 1800,
          "createdAt": "2026-01-01T02:04:40.123456+00:00"
        }
        """
        let ride = try JSONCoding.decode(Ride.self, json: rideJSON)
        XCTAssertEqual(ride.status, .processed)
        XCTAssertEqual(ride.visibility, .privateOnly)
        XCTAssertEqual(ride.startedAt, SampleData.referenceDate)
        XCTAssertEqual(ride.createdAt.timeIntervalSince1970, SampleData.referenceDate.timeIntervalSince1970 + 7480.123456, accuracy: 0.001)

        let summaryJSON = """
        {
          "ride": \(rideJSON),
          "quest": null,
          "questCompletion": null,
          "xpAwarded": 420,
          "xpBreakdown": [{"source": "QUEST_COMPLETED", "xp": 350}, {"source": "CLASS_BONUS", "xp": 70, "detail": {"questTitle": "x"}}],
          "newCells": 34, "newTerritoryMeters": 12600, "newRoadsMeters": 9800,
          "discoveries": [{"id": "88888888-8888-4888-8888-888888888888", "name": "Greenwich Foot Tunnel", "category": "LANDMARK",
                           "latitude": 51.48, "longitude": -0.01, "source": "OSM", "discoveredByUser": true}],
          "levelUps": [{"kind": "OVERALL", "from": 7, "to": 8}], "abilitiesUnlocked": [],
          "flags": []
        }
        """
        let summary = try JSONCoding.decode(AdventureSummary.self, json: summaryJSON)
        XCTAssertEqual(summary.xpAwarded, 420)
        XCTAssertEqual(summary.xpBreakdown[1].detail?["questTitle"]?.stringValue, "x")
        XCTAssertEqual(summary.levelUps.first?.kind, .overall)
        XCTAssertEqual(summary.levelUps.first?.to, 8)
        XCTAssertEqual(summary.discoveries.first?.category, .landmark)
        XCTAssertNil(summary.quest)
    }

    func testCharacterFromAPIDocSample() throws {
        let json = """
        {
          "id": "22222222-2222-4222-8222-222222222222",
          "name": "Rowan",
          "characterClass": "EXPLORER",
          "overallLevel": 8, "overallXP": 1820, "nextOverallLevelXP": 2200, "overallLevelFloorXP": 1500,
          "classLevel": 6, "classXP": 900, "nextClassLevelXP": 1200, "classLevelFloorXP": 700,
          "title": "Wanderer",
          "abilities": [{
            "ability": {
              "id": "explorer_trail_sense", "characterClass": "EXPLORER", "name": "Trail Sense",
              "description": "Reveal more interesting nearby paths.", "requiredClassLevel": 5, "maxRank": 3,
              "effects": [{"type": "QUEST_POI_VISIBILITY", "perRank": 0.15}]
            },
            "rank": 1, "unlocked": true, "canUnlock": false
          }],
          "unspentAbilityPoints": 1,
          "createdAt": "2026-01-01T00:00:00+01:00"
        }
        """
        let character = try JSONCoding.decode(RoadsAndRunesCore.Character.self, json: json)
        XCTAssertEqual(character.name, "Rowan")
        XCTAssertEqual(character.abilities.first?.ability.effects.first?.perRank, 0.15)
        XCTAssertEqual(character.overallLevelProgress, (1820.0 - 1500.0) / 700.0, accuracy: 1e-9)
        XCTAssertEqual(character.createdAt, SampleData.referenceDate.addingTimeInterval(-3600))
    }

    func testWorldSnapshot() throws {
        let json = """
        {
          "center": {"latitude": 51.49, "longitude": -0.04},
          "h3Resolution": 9,
          "cells": [{"h3": "89194ad1", "state": "VISITED", "firstVisitedAt": "2026-01-01T00:00:00Z"}, {"h3": "89194ad2", "state": "DISCOVERED"}],
          "discoveries": [],
          "questMarkers": [{"questId": "44444444-4444-4444-8444-444444444444", "title": "...", "latitude": 51.5, "longitude": -0.02, "difficulty": "MODERATE", "questType": "EXPLORE_REGION"}],
          "featureFlags": {"fog_of_war": true, "story_quests": false}
        }
        """
        let world = try JSONCoding.decode(WorldSnapshot.self, json: json)
        XCTAssertEqual(world.cells.count, 2)
        XCTAssertEqual(world.cells[0].state, .visited)
        XCTAssertEqual(world.cells[1].state, .discovered)
        XCTAssertNil(world.cells[1].firstVisitedAt)
        XCTAssertEqual(world.questMarkers.first?.difficulty, .moderate)
        XCTAssertNil(world.questMarkers.first?.status)
        XCTAssertTrue(world.isEnabled("fog_of_war"))
        XCTAssertFalse(world.isEnabled("story_quests"))
    }

    func testErrorEnvelope() throws {
        let json = """
        {"error": {"code": "QUEST_INVALID_TRANSITION", "message": "Quest cannot move from AVAILABLE to COMPLETED", "details": {"from": "AVAILABLE", "to": "COMPLETED"}}}
        """
        let envelope = try JSONCoding.decode(APIErrorEnvelope.self, json: json)
        XCTAssertEqual(envelope.error.code, APIErrorCode.questInvalidTransition)
        XCTAssertEqual(envelope.error.details?["to"]?.stringValue, "COMPLETED")
    }

    func testUnknownEnumValueFallsBackToUnknown() throws {
        let json = """
        {"id": "33333333-3333-4333-8333-333333333333", "name": "Bike", "bikeType": "EASY|MODERATE|HARD|EPIC", "allowGravel": true, "allowTrails": false, "maxTechnicalSurface": 1, "isDefault": false}
        """
        let bike = try JSONCoding.decode(Bike.self, json: json)
        XCTAssertEqual(bike.bikeType, .unknown)
        XCTAssertTrue(bike.bikeType.isUnknown)
        XCTAssertEqual(try JSONCoding.decode([Difficulty].self, json: "[\"EPIC\", \"LEGENDARY\"]"), [.epic, .unknown])
    }

    func testPageAndTokenResponse() throws {
        let json = """
        {"items": [{"id": "33333333-3333-4333-8333-333333333333", "name": "Bike", "bikeType": "ROAD", "allowGravel": false, "allowTrails": false, "maxTechnicalSurface": 0, "isDefault": true}], "nextCursor": null}
        """
        let page = try JSONCoding.decode(Page<Bike>.self, json: json)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertFalse(page.hasMore)

        let tokenJSON = """
        {"accessToken": "a", "refreshToken": "r", "expiresIn": 3600, "isNewUser": true, "user": {
          "id": "11111111-1111-4111-8111-111111111111", "displayName": "Amir", "avatarUrl": null, "createdAt": "2026-01-01T00:00:00Z", "hasCharacter": true,
          "settings": {"defaultRideVisibility": "PRIVATE", "batteryMode": "BALANCED", "mapStyle": "ADVENTURE", "stravaUploadMode": "NEVER", "units": "METRIC"}}}
        """
        let token = try JSONCoding.decode(TokenResponse.self, json: tokenJSON)
        XCTAssertTrue(token.isNewUser)
        XCTAssertEqual(token.user.settings.batteryMode, .balanced)
        let tokens = AuthTokens(response: token, now: SampleData.referenceDate)
        XCTAssertEqual(tokens.expiresAt, SampleData.referenceDate.addingTimeInterval(3600))
        XCTAssertFalse(tokens.isExpired(at: SampleData.referenceDate))
        XCTAssertTrue(tokens.isExpired(at: SampleData.referenceDate.addingTimeInterval(3600)))
    }

    func testEncodingUsesCamelCaseAndISODates() throws {
        let body = RideComplete(endedAt: SampleData.referenceDate, distanceMeters: 100, durationSeconds: 60, elevationGainMeters: 5,
                                objectiveEvents: [ObjectiveEvent(objectiveId: SampleData.objectiveVisitId, occurredAt: SampleData.referenceDate, latitude: 51.49, longitude: -0.04)])
        let data = try JSONCoding.encode(body)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"endedAt\":\"2026-01-01T00:00:00.000Z\""), text)
        XCTAssertTrue(text.contains("\"objectiveEvents\""))
        XCTAssertTrue(text.contains("\"cellsVisited\":[]"))
        let decoded = try JSONCoding.decode(RideComplete.self, from: data)
        XCTAssertEqual(decoded, body)

        let patch = try JSONCoding.encode(RidePatch(title: "Sunday loop"))
        XCTAssertEqual(String(decoding: patch, as: UTF8.self), "{\"title\":\"Sunday loop\"}")
    }

    func testISO8601Parsing() {
        XCTAssertEqual(ISO8601.parse("2026-01-01T00:00:00Z"), SampleData.referenceDate)
        XCTAssertEqual(ISO8601.parse("2026-01-01T00:00:00.5Z")?.timeIntervalSince1970 ?? 0, SampleData.referenceDate.timeIntervalSince1970 + 0.5, accuracy: 1e-6)
        XCTAssertEqual(ISO8601.parse("2025-12-31T23:00:00-01:00"), SampleData.referenceDate)
        XCTAssertEqual(ISO8601.parse("2026-01-01"), SampleData.referenceDate)
        XCTAssertNil(ISO8601.parse("not a date"))
        XCTAssertEqual(ISO8601.string(from: SampleData.referenceDate), "2026-01-01T00:00:00.000Z")
        XCTAssertEqual(ISO8601.parse(ISO8601.string(from: Date(timeIntervalSince1970: 1_000_000_000.25)))?.timeIntervalSince1970 ?? 0, 1_000_000_000.25, accuracy: 1e-3)
    }
}
