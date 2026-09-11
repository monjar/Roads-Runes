import XCTest
@testable import RoadsAndRunesCore

/// A real processed-ride summary from the API: quest completed, two level-ups, an
/// ability unlocked, discoveries on the way. The app polls `/rides/{id}/summary`
/// until it decodes, so a mismatch here means no "Adventure complete" screen.
final class AdventureSummaryDecodingTests: XCTestCase {
    func testProcessedQuestRideSummaryDecodes() throws {
        let summary = try JSONCoding.makeDecoder().decode(AdventureSummary.self, from: Data(Self.json.utf8))
        XCTAssertEqual(summary.xpAwarded, 898)
        XCTAssertEqual(summary.levelUps.count, 2)
        XCTAssertEqual(summary.abilitiesUnlocked.first?.name, "Trail Sense")
        XCTAssertEqual(summary.discoveries.count, 3)
        XCTAssertEqual(summary.questCompletion?.quest.status, .completed)
    }

    static let json = #"""
{
  "ride": {
    "id": "7afb0d83-be8a-43ae-b218-f789cb5058f1",
    "clientRideId": "86d96b8c-4a93-4928-a27a-0e00969de8d5",
    "status": "PROCESSED",
    "title": null,
    "startedAt": "2026-09-11T18:25:28.170000Z",
    "endedAt": "2026-09-11T18:48:02.573000Z",
    "distanceMeters": 6951.4,
    "durationSeconds": 1245,
    "movingSeconds": 1245,
    "elevationGainMeters": 0.0,
    "activeCalories": null,
    "averageSpeedMps": 5.58,
    "maxSpeedMps": 22.03,
    "questId": "7efe3144-f7d1-4e2b-90bb-4aa5377acfc7",
    "bikeId": "827c7109-a491-4002-929c-4a33ac239235",
    "routeId": "c3f49850-9cd8-465f-b68b-a8c21976b943",
    "visibility": "PRIVATE",
    "healthKitWorkoutId": "57BBE323-318B-4120-8C18-FC6CD8D305EC",
    "pointCount": 500,
    "flags": [],
    "createdAt": "2026-09-11T18:25:28.290592Z"
  },
  "quest": {
    "id": "7efe3144-f7d1-4e2b-90bb-4aa5377acfc7",
    "questType": "VISIT_POI",
    "characterClass": "EXPLORER",
    "templateId": "EXPLORER_UNVISITED_PARK",
    "title": "Green Beyond the Fog",
    "description": "Ladywell Fields lies past the edge of what you know. Go and stand in it.",
    "narrative": {
      "hook": "Ladywell Fields lies past the edge of what you know. Go and stand in it.",
      "source": "template",
      "completion": null
    },
    "difficulty": "EASY",
    "recommendedDistanceKm": 9.2,
    "estimatedDurationMinutes": 46,
    "baseXP": 157,
    "status": "COMPLETED",
    "expiresAt": "2026-09-25T12:08:13.773565Z",
    "storyQuestId": null,
    "partyId": null,
    "origin": {
      "latitude": 51.49,
      "longitude": -0.04
    },
    "objectives": [
      {
        "id": "0f947699-5954-459c-841b-66343022c8ed",
        "objectiveType": "VISIT_POI",
        "title": "Reach Ladywell Fields",
        "latitude": 51.455,
        "longitude": -0.0175,
        "radiusMeters": 80.0,
        "targetMeters": null,
        "targetCells": null,
        "targetElevationMeters": null,
        "targetCount": null,
        "discoveryId": "e5f9aac3-2ac1-4284-b69e-620addeae549",
        "required": true,
        "order": 1,
        "completionRule": "INDIVIDUAL",
        "status": "COMPLETED",
        "completedAt": "2026-09-11T18:44:37.445000Z",
        "provisional": false,
        "progress": {
          "current": 1.0,
          "target": 1.0
        },
        "extra": {
          "poiName": "Ladywell Fields",
          "category": "NATURE"
        }
      }
    ],
    "rewards": {
      "xp": 157,
      "items": [],
      "titles": []
    },
    "suggestedRouteId": "c3f49850-9cd8-465f-b68b-a8c21976b943",
    "rideId": "7afb0d83-be8a-43ae-b218-f789cb5058f1",
    "acceptedAt": "2026-09-11T18:25:28.104560Z",
    "startedAt": "2026-09-11T18:25:28.303464Z",
    "completedAt": "2026-09-11T18:48:02.573000Z",
    "createdAt": "2026-09-11T12:08:13.775031Z"
  },
  "questCompletion": {
    "quest": {
      "id": "7efe3144-f7d1-4e2b-90bb-4aa5377acfc7",
      "title": "Green Beyond the Fog",
      "baseXP": 157,
      "origin": {
        "latitude": 51.49,
        "longitude": -0.04
      },
      "rideId": "7afb0d83-be8a-43ae-b218-f789cb5058f1",
      "status": "COMPLETED",
      "partyId": null,
      "rewards": {
        "xp": 157,
        "items": [],
        "titles": []
      },
      "createdAt": "2026-09-11T12:08:13.775031Z",
      "expiresAt": "2026-09-25T12:08:13.773565Z",
      "narrative": {
        "hook": "Ladywell Fields lies past the edge of what you know. Go and stand in it.",
        "source": "template",
        "completion": null
      },
      "questType": "VISIT_POI",
      "startedAt": "2026-09-11T18:25:28.303464Z",
      "acceptedAt": "2026-09-11T18:25:28.104560Z",
      "difficulty": "EASY",
      "objectives": [
        {
          "id": "0f947699-5954-459c-841b-66343022c8ed",
          "extra": {
            "poiName": "Ladywell Fields",
            "category": "NATURE"
          },
          "order": 1,
          "title": "Reach Ladywell Fields",
          "status": "COMPLETED",
          "latitude": 51.455,
          "progress": {
            "target": 1.0,
            "current": 1.0
          },
          "required": true,
          "longitude": -0.0175,
          "completedAt": "2026-09-11T18:44:37.445000Z",
          "discoveryId": "e5f9aac3-2ac1-4284-b69e-620addeae549",
          "provisional": false,
          "targetCells": null,
          "targetCount": null,
          "radiusMeters": 80.0,
          "targetMeters": null,
          "objectiveType": "VISIT_POI",
          "completionRule": "INDIVIDUAL",
          "targetElevationMeters": null
        }
      ],
      "templateId": "EXPLORER_UNVISITED_PARK",
      "completedAt": "2026-09-11T18:48:02.573000Z",
      "description": "Ladywell Fields lies past the edge of what you know. Go and stand in it.",
      "storyQuestId": null,
      "characterClass": "EXPLORER",
      "suggestedRouteId": "c3f49850-9cd8-465f-b68b-a8c21976b943",
      "recommendedDistanceKm": 9.2,
      "estimatedDurationMinutes": 46
    },
    "levelUps": [
      {
        "to": 3,
        "from": 1,
        "kind": "OVERALL"
      },
      {
        "to": 3,
        "from": 1,
        "kind": "CLASS"
      }
    ],
    "xpAwarded": 898,
    "xpBreakdown": [
      {
        "xp": 157,
        "detail": {
          "base": 157,
          "modifier": 0.0
        },
        "source": "QUEST_COMPLETED"
      },
      {
        "xp": 40,
        "detail": {
          "optional": 0,
          "required": 1
        },
        "source": "QUEST_OBJECTIVE_COMPLETED"
      },
      {
        "xp": 330,
        "detail": {
          "cells": 24,
          "explored": 7
        },
        "source": "NEW_AREA_EXPLORED"
      },
      {
        "xp": 139,
        "detail": {
          "km": 6.95
        },
        "source": "NEW_ROAD_EXPLORED"
      },
      {
        "xp": 115,
        "detail": {
          "count": 3
        },
        "source": "DISCOVERY_FOUND"
      },
      {
        "xp": 117,
        "detail": {
          "class": "EXPLORER"
        },
        "source": "CLASS_BONUS"
      }
    ],
    "storyProgress": null,
    "titlesUnlocked": [],
    "abilitiesUnlocked": [
      {
        "id": "explorer_trail_sense",
        "name": "Trail Sense",
        "maxRank": 3,
        "description": "Reveal more interesting nearby paths.",
        "characterClass": "EXPLORER",
        "requiredClassLevel": 2
      }
    ]
  },
  "xpAwarded": 898,
  "xpBreakdown": [
    {
      "xp": 157,
      "detail": {
        "base": 157,
        "modifier": 0.0
      },
      "source": "QUEST_COMPLETED"
    },
    {
      "xp": 40,
      "detail": {
        "optional": 0,
        "required": 1
      },
      "source": "QUEST_OBJECTIVE_COMPLETED"
    },
    {
      "xp": 330,
      "detail": {
        "cells": 24,
        "explored": 7
      },
      "source": "NEW_AREA_EXPLORED"
    },
    {
      "xp": 139,
      "detail": {
        "km": 6.95
      },
      "source": "NEW_ROAD_EXPLORED"
    },
    {
      "xp": 115,
      "detail": {
        "count": 3
      },
      "source": "DISCOVERY_FOUND"
    },
    {
      "xp": 117,
      "detail": {
        "class": "EXPLORER"
      },
      "source": "CLASS_BONUS"
    }
  ],
  "newCells": 24,
  "newTerritoryMeters": 6951.4,
  "newRoadsMeters": 6951.4,
  "discoveries": [
    {
      "id": "e9db60e0-a855-42df-924c-542672664316",
      "name": "The Dog and Bell",
      "source": "CURATED",
      "category": "PUB",
      "latitude": 51.483,
      "longitude": -0.0292,
      "discoveredByUser": true
    },
    {
      "id": "e5f9aac3-2ac1-4284-b69e-620addeae549",
      "name": "Ladywell Fields",
      "source": "CURATED",
      "category": "NATURE",
      "latitude": 51.455,
      "longitude": -0.0175,
      "discoveredByUser": true
    },
    {
      "id": "f8864fe4-3ff3-406c-966c-3d39fffb72f6",
      "name": "Waterlink Way",
      "source": "CURATED",
      "category": "TRAIL",
      "latitude": 51.4562,
      "longitude": -0.0172,
      "discoveredByUser": true
    }
  ],
  "levelUps": [
    {
      "to": 3,
      "from": 1,
      "kind": "OVERALL"
    },
    {
      "to": 3,
      "from": 1,
      "kind": "CLASS"
    }
  ],
  "abilitiesUnlocked": [
    {
      "id": "explorer_trail_sense",
      "name": "Trail Sense",
      "maxRank": 3,
      "description": "Reveal more interesting nearby paths.",
      "characterClass": "EXPLORER",
      "requiredClassLevel": 2
    }
  ],
  "titlesUnlocked": [],
  "flags": []
}
"""#
}
