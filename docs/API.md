# Roads & Runes API

Base path: `/api/v1`. All requests and responses are JSON. All IDs are UUIDs
(string). All timestamps are ISO 8601 with timezone. All distances and
elevations are **metres**; durations are **seconds**. Clients convert units.

## Conventions

### Authentication

Every endpoint except `/auth/*` and `/health` requires
`Authorization: Bearer <accessToken>`. Access tokens are short-lived JWTs;
refresh tokens are opaque, stored server-side and rotated on use.

### Error schema

```json
{
  "error": {
    "code": "QUEST_INVALID_TRANSITION",
    "message": "Quest cannot move from AVAILABLE to COMPLETED",
    "details": {"from": "AVAILABLE", "to": "COMPLETED"}
  }
}
```

HTTP status maps: 400 validation, 401 unauthenticated, 403 forbidden,
404 not found, 409 invalid state transition / conflict, 422 semantic
validation, 429 rate limited, 500 internal.

Stable error codes used by the client:

```
VALIDATION_ERROR
UNAUTHENTICATED
FORBIDDEN
NOT_FOUND
CONFLICT
QUEST_INVALID_TRANSITION
RIDE_INVALID_STATE
RIDE_DUPLICATE
ROUTE_GENERATION_FAILED
QUEST_GENERATION_FAILED
FEATURE_DISABLED
RATE_LIMITED
```

### Pagination

List endpoints accept `limit` (default 25, max 100) and `cursor`. Responses:

```json
{"items": [...], "nextCursor": "opaque-or-null"}
```

### Field naming

JSON uses `camelCase`. Coordinates are `{"latitude": 51.49, "longitude": -0.04}`.
Geometry is returned as an array of coordinates (`[[lon, lat], ...]`, GeoJSON
order) under `coordinates` plus an `encodedPolyline` (Google polyline5).

---

## Auth

### `POST /auth/apple`

```json
{"identityToken": "<apple id token>", "authorizationCode": "...", "fullName": {"givenName": "A", "familyName": "B"}}
```

Response:

```json
{"accessToken": "...", "refreshToken": "...", "expiresIn": 3600, "isNewUser": true, "user": User}
```

### `POST /auth/refresh` → same token response. Body `{"refreshToken": "..."}`.

### `POST /auth/dev`

Only when `DEV_AUTH_ENABLED=true` (never in production). Body
`{"subject": "dev-user-1", "displayName": "Dev"}` → token response.

---

## Users

`User`:

```json
{
  "id": "uuid",
  "displayName": "Amir",
  "avatarUrl": null,
  "createdAt": "2026-01-01T00:00:00Z",
  "hasCharacter": true,
  "settings": {
    "defaultRideVisibility": "PRIVATE",
    "batteryMode": "BALANCED",
    "mapStyle": "ADVENTURE",
    "stravaUploadMode": "NEVER",
    "units": "METRIC"
  }
}
```

- `GET /users/me`
- `PATCH /users/me` — any subset of `displayName`, `avatarUrl`, `settings`.
- `GET /users/{id}` → `PublicProfile`:

```json
{
  "id": "uuid", "displayName": "...", "avatarUrl": null,
  "characterClass": "EXPLORER", "overallLevel": 8, "title": "Wanderer",
  "questsCompleted": 12, "discoveriesFound": 30, "favouriteTerrain": "GRAVEL",
  "friendship": "NONE|REQUEST_SENT|REQUEST_RECEIVED|FRIENDS|BLOCKED",
  "recentAdventures": [AdventureSummaryPublic]
}
```

Never includes home location, ride start/end points or live location.

---

## Character

`Character`:

```json
{
  "id": "uuid",
  "name": "Rowan",
  "characterClass": "EXPLORER",
  "overallLevel": 8, "overallXP": 1820, "nextOverallLevelXP": 2200, "overallLevelFloorXP": 1500,
  "classLevel": 6, "classXP": 900, "nextClassLevelXP": 1200, "classLevelFloorXP": 700,
  "title": "Wanderer",
  "abilities": [AbilityState],
  "unspentAbilityPoints": 1,
  "createdAt": "..."
}
```

`Ability` / `AbilityState`:

```json
{
  "ability": {
    "id": "explorer_trail_sense",
    "characterClass": "EXPLORER",
    "name": "Trail Sense",
    "description": "Reveal more interesting nearby paths.",
    "requiredClassLevel": 5,
    "maxRank": 3,
    "effects": [{"type": "QUEST_POI_VISIBILITY", "perRank": 0.15}]
  },
  "rank": 1,
  "unlocked": true,
  "canUnlock": false
}
```

- `POST /character` `{"name": "Rowan", "characterClass": "EXPLORER"}` → `Character` (409 if exists; 403 `FEATURE_DISABLED` for classes behind flags).
- `GET /character`
- `GET /character/abilities` → `[AbilityState]`
- `POST /character/abilities/{abilityId}/unlock` → `Character`
- `GET /character/bikes` → `[Bike]`; `POST /character/bikes`; `PATCH /character/bikes/{id}`; `DELETE /character/bikes/{id}`

`Bike`:

```json
{"id": "uuid", "name": "Boardman ADV 8.8", "bikeType": "GRAVEL", "allowGravel": true, "allowTrails": true, "maxTechnicalSurface": 2, "isDefault": true}
```

`bikeType ∈ ROAD | GRAVEL | MOUNTAIN | HYBRID | FOLDING | OTHER`.

- `GET /character/rider-profile`, `PUT /character/rider-profile`

`RiderProfile`:

```json
{
  "comfortableDistanceKm": 30, "comfortableElevationGain": 400, "maxPreferredGradient": 8,
  "trafficTolerance": 0.3, "gravelComfort": 0.6, "technicalTrailComfort": 0.2, "cyclewayPreference": 0.8
}
```

---

## World

### `GET /world?latitude&longitude&radiusMeters=5000`

```json
{
  "center": {"latitude": 51.49, "longitude": -0.04},
  "h3Resolution": 9,
  "cells": [{"h3": "89194ad1...", "state": "VISITED", "firstVisitedAt": "..."}],
  "discoveries": [DiscoverySummary],
  "questMarkers": [{"questId": "uuid", "title": "...", "latitude": 51.5, "longitude": -0.02, "difficulty": "MODERATE", "questType": "EXPLORE_REGION"}],
  "featureFlags": {"fog_of_war": true, "story_quests": false}
}
```

Cell states: `UNSEEN` (omitted), `DISCOVERED`, `VISITED`, `EXPLORED`.

### `GET /world/exploration?minLat&minLon&maxLat&maxLon` → `{ "h3Resolution": 9, "cells": [...] }`

### `GET /world/exploration/stats`

```json
{
  "cellsVisited": 412, "cellsExplored": 130, "newTerritoryKm": 96.2, "uniqueRoadsKm": 210.4,
  "regionsVisited": 7, "questsCompleted": 12, "discoveriesFound": 30, "storyQuestsCompleted": 0,
  "totalDistanceMeters": 812000, "totalElevationMeters": 6200
}
```

---

## Quests

`Quest` (a quest instance owned by the user):

```json
{
  "id": "uuid",
  "questType": "EXPLORE_REGION",
  "characterClass": "EXPLORER",
  "templateId": "EXPLORER_NEW_TERRITORY",
  "title": "Beyond the Water",
  "description": "...",
  "narrative": {"hook": "...", "completion": "..."},
  "difficulty": "EASY|MODERATE|HARD|EPIC",
  "recommendedDistanceKm": 28,
  "estimatedDurationMinutes": 120,
  "baseXP": 350,
  "status": "AVAILABLE|ACCEPTED|ACTIVE|COMPLETED|ABANDONED|FAILED|EXPIRED",
  "expiresAt": null,
  "storyQuestId": null,
  "origin": {"latitude": 51.49, "longitude": -0.04},
  "objectives": [Objective],
  "rewards": {"xp": 350, "items": [], "titles": []},
  "suggestedRouteId": null,
  "acceptedAt": null, "startedAt": null, "completedAt": null
}
```

`Objective`:

```json
{
  "id": "uuid",
  "objectiveType": "VISIT_LOCATION",
  "title": "Reach Old Station",
  "latitude": 51.49, "longitude": -0.04, "radiusMeters": 50,
  "targetMeters": null, "targetCells": null, "targetElevationMeters": null,
  "required": true, "order": 1,
  "completionRule": "INDIVIDUAL",
  "status": "PENDING|COMPLETED|SKIPPED",
  "completedAt": null,
  "progress": {"current": 0, "target": 1}
}
```

Objective types: `VISIT_LOCATION, VISIT_REGION, EXPLORE_DISTANCE, EXPLORE_NEW_ROADS, REACH_ELEVATION, COMPLETE_DISTANCE, COMPLETE_CLIMB, VISIT_POI, PHOTO_LOCATION, WRITE_NOTE, VISIT_MULTIPLE_LOCATIONS, RETURN_TO_START, COMPLETE_WITH_FRIEND, COMPLETE_ROUTE`.

- `GET /quests?latitude&longitude&status=AVAILABLE&limit` → paginated. If the
  user has fewer than 3 `AVAILABLE` quests near the point the server
  generates more (idempotent within a Redis-cached window).
- `POST /quests/generate` `{"latitude","longitude","count":3,"request":"optional free text"}` → `{"items":[Quest]}`
- `GET /quests/{id}`
- `POST /quests/{id}/accept` → `Quest` (AVAILABLE→ACCEPTED)
- `POST /quests/{id}/start` `{"rideId": "uuid|null"}` → `Quest` (ACCEPTED→ACTIVE)
- `POST /quests/{id}/progress` — client-observed objective events, batched:

```json
{"events": [{"objectiveId": "uuid", "occurredAt": "...", "latitude": 51.49, "longitude": -0.04, "value": null}]}
```

Returns `Quest`. Server marks objectives provisionally complete; ride
post-processing re-validates.

- `POST /quests/{id}/complete` `{"rideId": "uuid"}` → `QuestCompletion`
  (ACTIVE→COMPLETED only; otherwise 409 `QUEST_INVALID_TRANSITION`).
- `POST /quests/{id}/abandon` → `Quest`

`QuestCompletion`:

```json
{
  "quest": Quest,
  "xpAwarded": 420,
  "xpBreakdown": [{"source": "QUEST_COMPLETED", "xp": 350}, {"source": "CLASS_BONUS", "xp": 70}],
  "levelUps": [{"kind": "OVERALL|CLASS", "from": 7, "to": 8}],
  "abilitiesUnlocked": [Ability],
  "titlesUnlocked": ["Wanderer"],
  "storyProgress": null
}
```

---

## Routes

### `POST /routes/generate`

```json
{
  "origin": {"latitude": 51.49, "longitude": -0.04},
  "destination": null,
  "waypoints": [],
  "bikeId": "uuid",
  "questId": "uuid|null",
  "distanceTargetKm": 30,
  "loop": true,
  "preferences": {
    "trafficAversion": 0.8, "cyclewayPreference": 0.9, "gravelPreference": 0.6,
    "scenicPreference": 0.8, "hillTolerance": 0.4
  },
  "request": "around 30 km, quiet roads, some gravel and a pub near the end"
}
```

Response `{"alternatives": [RouteOption], "parsedRequest": RoutePreferences|null}`.

`RouteOption`:

```json
{
  "id": "uuid",
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
  "pois": [RoutePOI],
  "coordinates": [[-0.04, 51.49], ...],
  "encodedPolyline": "...",
  "instructions": [Instruction],
  "elevationSamples": [{"distanceMeters": 0, "elevationMeters": 22}],
  "climbs": [Climb]
}
```

`Instruction`:

```json
{"index": 0, "text": "Turn right onto Rotherhithe Street", "streetName": "Rotherhithe Street", "sign": "RIGHT", "distanceMeters": 180, "durationSeconds": 40, "coordinateIndex": 12, "latitude": 51.5, "longitude": -0.04}
```

`sign ∈ CONTINUE | SLIGHT_LEFT | LEFT | SHARP_LEFT | SLIGHT_RIGHT | RIGHT | SHARP_RIGHT | U_TURN | ROUNDABOUT | FINISH | WAYPOINT`.

`RoutePOI`:

```json
{"discoveryId": "uuid", "name": "The Crown", "category": "PUB", "latitude": 51.5, "longitude": -0.03,
 "routePositionMeters": 24600, "detourMeters": 600, "detourSeconds": 180, "estimatedArrivalSeconds": 5400}
```

- `GET /routes/{id}` → `RouteOption`
- `GET /routes/{id}/package` → `RoutePackage` (everything needed offline):

```json
{"route": RouteOption, "quest": Quest|null, "pois": [RoutePOI], "mapRegion": {"minLat":..,"minLon":..,"maxLat":..,"maxLon":..}, "generatedAt": "..."}
```

---

## Rides

`Ride`:

```json
{
  "id": "uuid", "clientRideId": "uuid",
  "status": "RECORDING|UPLOADED|PROCESSING|PROCESSED|FLAGGED|DISCARDED",
  "startedAt": "...", "endedAt": null,
  "distanceMeters": 32400, "durationSeconds": 7480, "movingSeconds": 7000,
  "elevationGainMeters": 340, "activeCalories": 876,
  "averageSpeedMps": 4.3, "maxSpeedMps": 11.2,
  "questId": "uuid|null", "bikeId": "uuid|null", "routeId": "uuid|null",
  "visibility": "PRIVATE|FRIENDS|PUBLIC",
  "healthKitWorkoutId": null,
  "pointCount": 1800,
  "createdAt": "..."
}
```

- `POST /rides` `{"clientRideId": "uuid", "startedAt": "...", "questId": null, "bikeId": null, "routeId": null}` → `Ride`. Duplicate `clientRideId` returns the existing ride (idempotent).
- `POST /rides/{id}/points` — batched during the ride when network allows (optional; the complete call may carry everything):

```json
{"points": [{"latitude": 51.49, "longitude": -0.04, "timestamp": "...", "altitudeMeters": 12.0, "horizontalAccuracyMeters": 8.0, "speedMps": 4.2, "heartRateBpm": 132}]}
```

- `POST /rides/{id}/exploration` `{"cellsVisited": ["89194ad1..."]}` batched; idempotent.
- `POST /rides/{id}/complete`:

```json
{
  "endedAt": "...", "distanceMeters": 32400, "durationSeconds": 7480, "movingSeconds": 7000,
  "elevationGainMeters": 340, "activeCalories": 876,
  "points": [...optional remaining points...],
  "cellsVisited": [...optional remaining cells...],
  "objectiveEvents": [{"objectiveId": "uuid", "occurredAt": "...", "latitude": 51.49, "longitude": -0.04}],
  "healthKitWorkoutId": null
}
```

Returns `{"ride": Ride, "processing": "QUEUED"}`. Post-processing runs as a
background job (validation, exploration, XP). Poll:

- `GET /rides/{id}/summary` → 202 while processing, then `AdventureSummary`:

```json
{
  "ride": Ride,
  "quest": Quest|null,
  "questCompletion": QuestCompletion|null,
  "xpAwarded": 420,
  "xpBreakdown": [...],
  "newCells": 34, "newTerritoryMeters": 12600, "newRoadsMeters": 9800,
  "discoveries": [DiscoverySummary],
  "levelUps": [...], "abilitiesUnlocked": [...],
  "flags": []
}
```

- `GET /rides` paginated, newest first. `GET /rides/{id}`. `GET /rides/{id}/geometry` → `{"coordinates": [...], "encodedPolyline": "..."}`.
- `PATCH /rides/{id}` `{"visibility": "FRIENDS", "title": "...", "notes": "..."}`
- `DELETE /rides/{id}`

---

## Discoveries

`DiscoverySummary`:

```json
{"id": "uuid", "name": "Greenwich Foot Tunnel", "category": "LANDMARK", "latitude": 51.48, "longitude": -0.01,
 "source": "OSM|CURATED|USER", "discoveredByUser": true, "discoveredAt": "..."}
```

`category ∈ NATURE | HISTORICAL | CULTURAL | FOOD | PUB | CAFE | VIEWPOINT | CYCLING | LANDMARK | TRAIL | CUSTOM`.

- `GET /discoveries?latitude&longitude&radiusMeters&category` → paginated
- `GET /discoveries/{id}` → `Discovery` (summary + `description`, `osmId`, `userDiscovery`)
- `PUT /discoveries/{id}/user` `{"note": "...", "rating": 4, "tags": ["coffee"], "photoIds": []}` → `UserDiscovery`
- `GET /discoveries/mine` → paginated `UserDiscovery`

---

## Journal

- `GET /journal/adventures` → paginated `AdventureEntry` (`{ride, quest, xpAwarded, discoveries, newTerritoryMeters, photos, notes}`)
- `GET /journal/stats` → same shape as `/world/exploration/stats` plus secondary speed stats.

---

## Social

- `GET /friends` → `[FriendSummary]`
- `GET /friends/requests` → `{"incoming": [...], "outgoing": [...]}`
- `POST /friends/requests` `{"userId": "uuid"}`
- `POST /friends/requests/{id}/accept`, `POST /friends/requests/{id}/decline`
- `DELETE /friends/{userId}`
- `POST /friends/{userId}/block`
- `GET /feed` → paginated `[FeedEvent]` (`FRIEND_QUEST_COMPLETED | FRIEND_DISCOVERY | FRIEND_LEVEL_UP | FRIEND_NEW_REGION`)

Parties:

- `POST /parties` `{"questId": "uuid", "memberIds": ["uuid"]}` → `Party`
- `GET /parties`, `GET /parties/{id}`
- `POST /parties/{id}/invite` `{"userId": "uuid"}`; `POST /parties/{id}/accept`; `POST /parties/{id}/leave`
- `POST /parties/{id}/ready`, `POST /parties/{id}/start`, `POST /parties/{id}/cancel`

`Party.status ∈ FORMING | READY | ACTIVE | COMPLETED | CANCELLED`.

---

## Integrations

- `GET /integrations/strava` → `{"connected": false, "athleteName": null, "uploadMode": "NEVER|ASK|AUTO"}`
- `GET /integrations/strava/authorize` → `{"url": "https://www.strava.com/oauth/authorize?..."}`
- `POST /integrations/strava/callback` `{"code": "..."}`
- `DELETE /integrations/strava`
- `POST /integrations/strava/upload/{rideId}` → `{"status": "QUEUED"}`
- `GET /rides/{id}/export?format=gpx|tcx` → file

---

## Devices & notifications

- `PUT /devices` `{"token": "apns", "platform": "IOS|WATCHOS", "environment": "SANDBOX|PRODUCTION"}`
- `DELETE /devices/{token}`

## Meta

- `GET /health` → `{"status": "ok", "version": "..."}`
- `GET /config` → `{"featureFlags": {...}, "h3Resolution": 9, "levels": {"max": 50}}`
