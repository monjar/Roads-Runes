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
OBJECT_OUT_OF_RANGE
OBJECT_GONE
OBJECT_NOT_CLAIMABLE
GPS_TOO_WEAK
CLAIM_TOO_FAST
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
- `GET /users/search?q=<name>&limit=10` → `[FriendSummary]`. People by display name, for
  adding as friends; never the searcher, never anyone in a blocked relationship. The app
  used to ask for a user id, which nobody knows.
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
  "title": "Familiar Face", "titlePinned": false,
  "abilities": [AbilityState],
  "unspentAbilityPoints": 1,
  "createdAt": "..."
}
```

Since 0.6.2 `unspentAbilityPoints` is the knacks this trade has to choose,
derived from the trade's level less what it has learned, and only the current
trade's knacks count anywhere (the sheet, quests, XP). `titlePinned` (optional)
is true once the player has chosen what to wear. `sheet` gains `vsEldersPct`,
`lateRoadPct`, `lateRoadAfterMeters` and `wordOldPlacesPct` (all optional), and
`xpPct` / `coinPct` carry the XP and coin knacks.

`Ability` / `AbilityState`:

```json
{
  "ability": {
    "id": "explorer_trail_sense",
    "characterClass": "EXPLORER",
    "name": "Trail Sense",
    "description": "Quest stops are looked for 15% further out, and new ground does 5% more against things, per rank.",
    "requiredClassLevel": 2,
    "maxRank": 3,
    "effects": [{"type": "QUEST_POI_VISIBILITY", "perRank": 0.15}, {"type": "DAMAGE_PCT", "kind": "GROUND", "perRank": 0.05}]
  },
  "rank": 1,
  "unlocked": true,
  "canUnlock": false
}
```

`ability.working` (0.6.0, optional) says whether the server acts on that knack
yet; the character sheet marks the others "not yet".

- `GET /character/classes` → `[ClassInfo]`: `{"id": "WIZARD", "name": "Wizard", "tagline": "Cuts the runes again. Looks twice.", "description": "…", "enabled": true, "guild": "the Cutters", "saying": "Look twice, then once more.", "crest": "wizard"}`. `guild`, `saying` and `crest` are optional (0.6.0); a trade's lore is in `docs/WORLD.md`.
- `POST /character` `{"name": "Rowan", "characterClass": "EXPLORER"}` → `Character` (409 if exists; 403 `FEATURE_DISABLED` for classes behind flags).
- `GET /character`
- `GET /character/abilities` → `[AbilityState]`
- `POST /character/abilities/{abilityId}/unlock` → `Character` (409 `NO_ABILITY_POINTS` with no knack to choose)
- `GET /character/titles` (0.6.2) → `[Title]`, every title there is, the earned first:
  `{"slug": "level-5", "name": "Familiar Face", "source": "LEVEL|ARC|DEED|CAST", "how": "Reach level 5.", "earned": true, "earnedAt": "...", "worn": true}`
- `PUT /character/title` (0.6.2) `{"slug": "arc-first-light"}` → `Character`: wear an earned title
  and keep it (409 `TITLE_NOT_EARNED`); `{"slug": null}` wears the newest earned again.

A title is worn as soon as it is earned until the player chooses one. Since 0.7.0 there are deed
titles (`DEED`, five per deed) and the cast's (`CAST`): finishing enough of one person's notices
(by `narrative.poster.castId`) earns their title, which is all the standing with the cast there is. Level titles are Passer-by (1),
Familiar Face (5), Roadwise (10), Journeyman (20), Waywright (30), Old Hand (40) and Known to the
Roads (50); finishing an arc gives its own. New XP sources in 0.6.2: `PATHFINDER`, `FAR_WANDERER`,
`WELCOME_BACK` (the first outing after 14 days or more pays its first kilometre twice), and
`STORY_ARC_COMPLETED` is paid once per arc whichever way its last step was finished.
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

## Codex

### `GET /codex` (flag `codex`)

The world in its own words, and what this player has met of it. Nothing is
stored: "met" is read from the player's own world objects. Pages about
mechanics the server is not running yet (a page whose `flag` is off) are left
out.

```json
{
  "chapters": [{"id": "WORLD", "title": "The Old Roads"}, {"id": "CREATURES", "title": "Things that settle"}, "…"],
  "entries": [{"id": "the-fog", "chapter": "WORLD", "title": "The fog", "body": ["Ground you have not read. …"],
               "by": "enid-sallow", "byName": "Enid Sallow", "characterClass": null}],
  "creatures": [{
    "id": "fen-troll", "name": "Fen Troll", "family": "WATER", "flavour": "Sleeps by the water; wakes for footsteps.",
    "hint": "Keeps to water.", "page": "…", "leaves": "a bridge nail",
    "wants": ["ROAD", "RUNE"], "minds": ["WORD"], "rune": "dagaz",
    "elders": [{"tier": 2, "name": "Culvert Troll", "flavour": "…", "seen": true}, {"tier": 3, "name": "Old Arch", "flavour": "…", "seen": false}],
    "sigil": {"body": "hulk", "feature": "horns", "mark": "water"},
    "state": "MET", "seenCount": 3, "seenOffCount": 1, "firstSeenAt": "…", "lastSeenOffAt": "…"
  }],
  "runes": [{"id": "raido", "name": "Raido", "order": 5, "six": "ROAD", "gloss": "The road-rune. …", "lends": "the road",
             "roadForm": "LOOP", "state": "HELD", "found": 2}],
  "sixes": [{"id": "ROAD", "name": "the Road Six", "how": "Found lying anywhere. …"}],
  "people": [{"id": "ada-pym", "name": "Ada Pym", "role": "Keeps the board", "posts": "ANY", "page": "…", "pageBy": "enid-sallow", "lines": ["…"]}],
  "counts": {"creaturesSeenOff": 1, "creaturesSeen": 2, "creaturesTotal": 12, "runesHeld": 1, "runesTotal": 24}
}
```

`state` for a creature is `UNSEEN` (never placed for this player), `SEEN` (on
their map at least once) or `MET` (seen off, or loosened). A rune is `HELD` or
`NOT_FOUND`. `wants`/`minds` are kinds of effort (`ROAD`, `GROUND`, `CLIMB`,
`RUNE`, `WORD`); the app shows them only when `effort_combat` is on. A monster
placed from 0.6.0 carries `speciesId` in its payload, and its `name` is its
elder's name at tiers 2 and 3.

With `effort_combat` on (0.6.1) a monster's `monster` block gains `holdMax`,
`holdLeft`, `wants`, `minds`, `rune`, `roadForm` and sometimes `unpassedDays`,
and its `killMethods` is empty, so a phone from before 0.6.1 never judges a
fight. A ride summary's `worldObjects.fights[]` reports each fight
(`outcome` SEEN_OFF / LOOSENED / UNTOUCHED, `holdBefore`, `holdAfter`,
`damage` by kind, `finisher`, `wouldHaveDone`, and the thing's `latitude` and
`longitude` for the reckoning's ink mark), `missed[].reason` gains
`LOOSENED` and `UNTOUCHED`, and the XP breakdown gains `BLOWS_LANDED`.

A note sent as an encounter event (`method: LORE`, with `note`) is, with the
flag on, the word: the server places it on the trace at the fix nearest its
`occurredAt` and it lands on anything within 120 m. No event is sent for a
creature seen off by effort; the server reads the trace.

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

### `GET /world/objects?latitude&longitude&radiusMeters=6000` → `[WorldObject]`

The chests, pieces and monsters placed for this player around the position given (placing them if
today's have not been). `GET /world/objects/{id}` is one of them; `GET /world/objects/bounty` is
today's bounty (`404 NO_BOUNTY` until the world has been looked at today).

```json
{
  "id": "uuid", "kind": "CHEST", "status": "SPAWNED", "tier": 1,
  "latitude": 51.4881, "longitude": -0.0202, "name": "Old chest", "anchorName": "Wall of the Ancestors",
  "bounty": false, "rewardAC": 25, "expiresAt": "...", "claimedAt": null,
  "monster": null, "setId": null, "piece": null, "claimRadiusMeters": 40,
  "setName": null, "setSize": null, "setOwned": null, "pieceOwned": null
}
```

A piece (`COLLECTABLE`) carries its set: `setId`, `piece`, `setName`, `setSize`, and, in the list for a
player, `setOwned` (how many different pieces of it they hold) and `pieceOwned` (they already hold this
one, so it is coins and not progress).

`kind` is `CHEST`, `COLLECTABLE` or `MONSTER`; `status` is `SPAWNED`, `CLAIMED` or `EXPIRED`.
`claimRadiusMeters` is how close the player must be to take it, and null for a monster.

### `POST /world/objects/{id}/claim`

Open a chest or pick up a piece from beside it. (A ride still claims whatever its trace passes; this
is for a player who has walked up to one.)

```json
{"latitude": 51.48835, "longitude": -0.0202, "horizontalAccuracyMeters": 8}
```

→ `{"object": WorldObject, "acAwarded": 25, "walletBalance": 185, "questCompleted": Quest|null,
"xpAwarded": 15, "levelUps": [], "setCompleted": {"id", "name", "bonusAC"}|null}`

It is worth the XP a ride past it would have given, and the piece that completes a set pays the set's
purse and XP there and then (`setCompleted`; `acAwarded` includes it).

The player must be within `claimRadiusMeters × 1.25`, plus the stated accuracy up to 25 m. Opening
the chest a quest points at completes that objective, and the quest when nothing else was asked
(`questCompleted`). It is paid once; a ride past it afterwards pays nothing more, though what was
taken by hand during a ride counts towards that ride's quest.

`409` with one of: `OBJECT_OUT_OF_RANGE` (`details.distanceMeters`, `details.radiusMeters`),
`OBJECT_GONE` (already claimed or expired), `OBJECT_NOT_CLAIMABLE` (a monster), `GPS_TOO_WEAK`
(accuracy worse than 65 m), `CLAIM_TOO_FAST` (more than 500 m from the last one, faster than 25 m/s).

### `POST /world/objects/lure`

A lamp left out: one creature comes to the nearest named place within 250 m of the spot, quota
aside, and the player's purse pays 50 coins only if something comes.

```json
{"latitude": 51.4990, "longitude": -0.0480}
```

→ `[WorldObject]` (the one that came). `409 NOTHING_TO_LURE` when there is no place to come to
(no charge); `409 INSUFFICIENT_AC` when the purse is short.

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
  "narrative": {"hook": "...", "completion": "...",
                "poster": {"castId": "nell-foss", "name": "Nell Foss", "line": "By the pond. Not there at lamp-lighting."}},
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

Objective types: `VISIT_LOCATION, VISIT_REGION, EXPLORE_DISTANCE, EXPLORE_NEW_ROADS, REACH_ELEVATION, COMPLETE_DISTANCE, COMPLETE_CLIMB, VISIT_POI, PHOTO_LOCATION, WRITE_NOTE, VISIT_MULTIPLE_LOCATIONS, RETURN_TO_START, COMPLETE_WITH_FRIEND, COMPLETE_ROUTE, RIDE_DURATION, SUSTAIN_SPEED, SLAY_MONSTER, OPEN_CHEST, COLLECT, INSCRIBE_RUNE, CARRY`.

0.7.0 adds two. `INSCRIBE_RUNE` asks for a rune round a place: `extra.roadForm` is `LOOP`,
`TRIANGLE`, `SQUARE` or `ZIGZAG` (a shape cut with the trace within `radiusMeters` of the
place, judged by the rune matcher), `NOTE` (a note of a few words sent as the objective's
`progress` event within reach) or `STOP` (staying within reach for `extra.stopSeconds`);
`extra.rune` names the rune. `CARRY` asks for the trace to reach the objective's place and
later `extra.to` (`{"latitude", "longitude", "name", "discoveryId"}`); `progress` counts 0, 1
(picked up) and 2 (delivered).

`RIDE_DURATION` counts minutes and `SUSTAIN_SPEED` the ride's average km/h (with a floor
in `extra.minDistanceMeters`, so a fast two kilometres does not pass); both are judged
server-side when the ride is processed. `PHOTO_LOCATION` and `WRITE_NOTE` need the rider
to act and complete through `POST /quests/{id}/progress`.

A puzzle objective (Wizard quests) omits `latitude`/`longitude`, `discoveryId` and the
place's name and category in `extra` until it is completed — the route generated for the
quest still passes the place, but the app cannot name or pin it, and neither the composed
story nor the model is told its name. The app renders such an objective as "hidden".

Every notice carries `narrative.poster` (0.6.2, optional): who put it up and one of their
lines, picked by seed and attached after the story is written. `narrative.completion` is
an authored line for every template and every story step.

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
- `GET /quests/{id}/route?latitude&longitude` → `RouteOption`: the quest's route from where the player is (spec §20 "suggested route"). A quest starts where the player stands: the route runs from the given position through the objectives still to do and back, with the rider's default bike and profile, and is stored as the quest's `suggestedRouteId`. It is returned unchanged while the player stays within 150 m of where it starts; further than that it is drawn again from the new position, and the quest's `origin` and any `RETURN_TO_START` objective move with it. Without a position the stored route is returned as it is. A route that cannot be drawn is `502 ROUTE_GENERATION_FAILED`, never a quest with no route and no reason. `POST /routes/generate` with the `questId` (the planner's "Tweak the route") adds alternatives without replacing it.
- The board (`GET /quests`) routes its `AVAILABLE` and `ACCEPTED` quests from the position it is given, and retires what cannot be done from there: a quest whose furthest target is beyond reach (18 km for a ride, scaled for feet, or 0.6 × the comfortable distance if that is more), and a quest whose chest or monster has gone. A quest about a world object expires when the object does.

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

### `GET /quests/story`

Every authored arc and where the rider stands in it. Behind the `story_quests`
flag; 403 when it is off.

```json
[{
  "slug": "first-light", "title": "First Light", "description": "…",
  "characterClass": null, "minLevel": 1, "unlocked": true,
  "quests": [
    {"slug": "first-light-out-of-the-door", "sequence": 1, "title": "Out of the Door",
     "description": "…", "state": "COMPLETED", "questId": null},
    {"slug": "first-light-something-green", "sequence": 2, "title": "Something Green",
     "description": "…", "state": "OPEN", "questId": "uuid"}
  ]
}]
```

`state` is `COMPLETED` (done), `OPEN` (on the board now, `questId` set), `READY`
(next up), `WAITING` (next up, but it cannot be set where the player is;
`waitingReason` says why) or `LOCKED` (waiting on the step before). Locked arcs are
returned too — `unlocked` says whether this player's class, level and the chapter
before have reached it. A step is put on the board by `GET /quests`
(`ensure_available`), one per track, and never expires.

0.6.2 adds to each arc (all optional): `track` (`MAIN`, the campaign; `SIDE`, a
trade's own arc), `act` and `actTitle`, `chapter`, `after` (the chapter that must be
finished first), `giver` (a cast id) and `reward` (`{"title", "ac"}`). Act I, "The
Board", is First Light, What Settles and The Rune at the Crossing; its finale places a
named elder bound to its step, which stays while the step is open. An arc's ending is
paid once, whichever way its last step was finished. See `docs/QUEST_SYSTEM.md`.

### `GET /quests/week` (0.6.2)

The week's notice: one goal an ISO week, a fixed target, paid once (150 coins and
200 XP) by the outing that meets it.

```json
{"week": "2026-W41", "kind": "OUTINGS|NEW_GROUND|PLACES|SEEN_OFF", "title": "Three outings this week.",
 "line": "Pinned Monday. Comes down Sunday night.", "postedBy": "Ada Pym", "target": 3, "unit": "outings",
 "progress": 1, "done": false, "paid": false, "coins": 150, "xp": 200, "endsAt": "..."}
```

## Runes and deeds (0.7.0)

Runes are the build. A rune is held from its first stone (picked up on an outing or by
hand, from the Road Six set anywhere and the Ground Six only on their own kind of ground);
after that each stone is a shard towards the next rank. Only inscribed runes act, each
changing one rule (`backend/app/inventory/config/runes.json`); a rank widens the rule's
number, never a damage percentage. Slots open at levels 1, 10 and 25.

- `GET /runes` → `{"runes": [Rune], "inscribed": ["raido"], "slots": 1, "slotsAtLevel": [1, 10, 25]}`,
  `Rune` = `{"id", "name", "six": "ROAD|GROUND", "gloss", "roadForm", "held", "rank", "shards", "inscribed",
  "rule" (what it does at its rank, or rank I), "nextRank": {"shards": 2, "coins": 100}|null}`
- `POST /runes/{id}/rank` → `Runes`: two stones and coins take it a rank deeper (409 `RUNE_NOT_HELD`,
  `RUNE_NEEDS_STONES`, `RUNE_MAX_RANK`, `INSUFFICIENT_AC`)
- `PUT /runes/inscribed` `{"runes": ["raido", "kenaz"]}` → `Runes` (409 `NO_SLOT`, `RUNE_NOT_HELD`,
  `RUNE_TWICE`, `LOADOUT_LOCKED` while a ride is recording)
- `GET /runes/cuts` → `[{"runeId", "name", "latitude", "longitude", "woke", "source": "WAKING|FIGHT|QUEST",
  "placeName", "cutAt", "rideId"}]`, for the marks on the maps
- `GET /character/deeds` → `{"deeds": [{"id": "LEGS|LUNGS|EYES|HAND|INK", "name", "what", "unit", "value",
  "tier", "next", "title", "frame"}], "records": [{"id": "RECORD_FURTHEST|RECORD_NEW_GROUND|RECORD_HIGHEST",
  "name", "unit", "value"}]}`

The sheet (`Character.sheet`, `Ride.loadout`) gains `inscribed` (`{"raido": 1}`) and `rules`
(`{"CARRIED_SCALE": 2.0}`). Cutting an inscribed rune's road form on an outing planned as its rune ride wakes it: it counts
a rank deeper for that outing and lands a rune blow on every creature within reach
(`worldObjects.woken`). A shape cut by chance on an ordinary outing wakes nothing. A ride summary gains `runesFound` (stones picked up) and `deeds`
(`{"reached": [{"deed", "name", "tier", "title", "frame"}], "records": [...]}`). Deed titles
join `GET /character/titles` (`source: DEED`).

Cartographer, Arcane Sight and Second Chance work from 0.7.0: a ring of ground read round
new cells (`discovered_via: CARTOGRAPHER`), rune stones likelier, and one missed optional
objective of a finished quest counting (`extra.forgiven`).

## Gear, the bag and the stall (0.7.2)

Gear is worn in five slots that open with level: Bell (1), Lantern (3), Bag (5), Map case
(13) and Keepsake (21). Fifteen items (`backend/app/inventory/config/gear.json`), Common,
Rare or Legendary; each changes a rule, never a damage percentage, and joins the runes'
rules on the sheet (`Character.sheet.rules`, `gear`, `lootFindPct`; sheet version 4). A
Legendary item comes to a player once, ever. Every change goes through
`inventory/service.py` and its idempotent ledger.

- `GET /inventory` → `Inventory`:
  ```json
  {"slots": [{"slot": "BELL", "name": "Bell", "opensAtLevel": 1, "open": true, "item": GearItem|null}],
   "bag": [GearItem], "bagSize": 20,
   "consumables": [{"id": "LAMP|MAP_FRAGMENT|REST_TOKEN|SEALED_CHEST_COMMON|SEALED_CHEST_RARE",
                    "name": "Lamp", "icon": "lantern", "text": "...", "count": 2}],
   "finishesSinceRare": 3, "levelRewardsPaid": [LevelReward]}
  ```
  `GearItem` = `{"id", "itemId": "tin-bell", "name": "Tin Bell", "slot", "rarity": "COMMON|RARE|LEGENDARY",
  "icon": "tinBell", "text": "Creatures show up from 500 m away.", "sellPrice", "equipped", "acquiredAt",
  "source": "MONSTER|BOUNTY|CHEST|QUEST|STALL|SEALED_CHEST"}`. The first call after 0.7.2 pays every level
  already reached, once, and lists it in `levelRewardsPaid`.
- `PUT /inventory/gear` `{"slot": "BELL", "itemId": uuid|null}` → `Inventory` (409 `WRONG_SLOT`,
  `SLOT_LOCKED`, `LOADOUT_LOCKED` during a recording ride)
- `POST /inventory/items/{id}/sell` → `Inventory` with `soldFor` and `walletBalance` (409 `TAKE_OFF_FIRST`)
- `POST /inventory/consumables/{id}/use` `{"latitude", "longitude"}` → `{"consumable", "revealedTiles",
  "placeName", "latitude", "longitude", "itemFound": ItemFound|null, "inventory": Inventory}`. A map piece
  reveals tiles round the nearest hidden place within 5 km (409 `NO_HIDDEN_PLACE`); a sealed chest gives an
  item of its rarity (409 `OPEN_LATER` during a journey). None held: 409 `NONE_LEFT`. Lamps are used by
  `POST /world/objects/lure` before coins, and rest tokens by the streak, on their own.
- `GET /inventory/stall` → `{"open", "opensAtLevel": 3, "week": "2026-W41", "resetsAt",
  "offers": [{"id": "w41-0", "kind": "GEAR|CONSUMABLE", "itemId", "consumable", "name", "rarity", "icon",
  "slot", "text", "price", "bought"}]}`: four offers a week, the same all week.
- `POST /inventory/stall/{offerId}/buy` → `Inventory` (409 `STALL_CLOSED`, `ALREADY_BOUGHT`,
  `INSUFFICIENT_AC`)
- `GET /inventory/levels` → `[{"level": 3, "reached": true, "rewards": [{"kind":
  "SLOT|RUNE_SLOT|STALL|TITLE|CONSUMABLE", "text": "Lantern slot opens", "icon", "consumable", "count",
  "slot", "level"}]}]` for levels 1 to 50: every level gives something.

New coin kinds in `GET /wallet/transactions`: `STALL`, `ITEM_SOLD`.

**What a journey found.** A ride summary (and `POST /world/objects/{id}/claim`, as `itemFound`) gains
`itemsFound`: `[{"kind": "GEAR|CONSUMABLE", "inventoryItemId", "itemId", "consumable", "name", "icon",
"rarity", "slot", "source": "MONSTER|CHEST|QUEST|BOUNTY", "fromName": "Fen Troll", "soldOnTheSpot": false,
"soldFor": null}]`. A drop into a full bag (20) is sold on the spot. `streak.restTokenUsed` says a rest
token kept the streak over a missed day; `levelUps[].rewards` lists what each new level gave. Hard quests
carry a Rare item in `rewards.items` (`{"itemId", "name", "rarity", "icon", "slot"}`), epic ones sometimes a
Legendary.

**Creatures.** Twenty-four species; every `monster.sigil` carries an `icon` (a `GameIcon` name).
`monster.variant` = `{"id": "STUBBORN|SKITTISH|MOSSY", "name": "Stubborn", "text"}` and `displayName`
("Stubborn Fen Troll"). A creature that gets away weakened twice from the same place comes back once as a
grudge: `monster.grudge` = `{"epithet": "Grumpy", "line"}`, named "Fen Troll the Grumpy". The Codex
creature page gains `trophies` (`{"name": "a bridge nail", "count": 3}`).

**The written entry** (flag `chronicle_llm`, off): after a ride is counted, a job may write
`entryWritten` (`{"lines": [...], "by": "model"}`) on the ride and its journal entry. The composed
`entry` stays; the app shows the written one when there is one.

## Routes

### `POST /routes/rune` (0.7.0)

A rune ride: up to three routes whose waypoints on the road network make a rune's road
form, starting where the player is.

```json
{"origin": {"latitude": 51.49, "longitude": -0.04}, "rune": "raido", "activity": "RIDE", "bikeId": null}
```

→ `{"alternatives": [RouteOption], "rune": "raido", "roadForm": "LOOP", "hint": "Cut Raido here: a loop, about 2.4 km.", "engine": "graphhopper"}`.
Loops, triangles and squares on a bike, zigzags on foot (409 `RUNE_NOT_FOR_ACTIVITY`); a
rune with no road form is 409 `RUNE_NOT_A_SHAPE`. Each route's label is the rune's name and
its `request` carries `rune` and `roadForm`.

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

`request` is free text, read by Claude into preferences (there is no keyword parser
behind it — with no provider configured the request is reported unread rather than
guessed at). Three of those preferences change where the ride goes:

* **a place** — "a ride **in Notting Hill** with 5 pubs". The phrase is resolved by
  `app/routing/geocode.py` (Photon, then Nominatim, both biased to within 60 km of
  `origin`, answers cached). If the place is more than 2 km away the ride is planned
  *there*, and the response carries `parsedRequest.startsAt` so the app can say where the
  ride begins. A phrase that resolves to nothing is ignored — the geocoder is what decides
  whether a phrase was a place.
* **a place to pass through** — "visit **the Moby Dick** then to Aragon Tower". Each
  name in `via` is resolved as a point, the way `destination` is, and becomes a real
  waypoint in the order it was said. A name is what separates this from a stop: "2 pubs"
  names none. Resolved places come back in `parsedRequest.via`; one that resolves to
  nothing is named in `parsedRequest.notes` rather than dropped in silence.
* **how many stops** — "about **5 pubs**". That many places of the category are chosen
  around the centre, one per sector of the circle so the ride threads them rather than
  doubling back, and they are passed to the routing engine as waypoints. They come back in
  `parsedRequest.stops` as `[{"name", "latitude", "longitude"}]` and appear in the route's
  `pois` like any other stop.


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
 "routePositionMeters": 24600, "detourMeters": 600, "detourSeconds": 180, "estimatedArrivalSeconds": 5400,
 "relevance": 0.9, "requested": true}
```

`requested` marks a stop the rider asked for ("with about 5 pubs"): it was routed through as a
waypoint and is always listed, whatever its detour. The rest are places the route happens to pass.

### `POST /routes/{id}/reroute`

Off the route, mid-ride: one new route from where the rider is.

```json
{
  "origin": {"latitude": 51.5031, "longitude": -0.0612},
  "progressMeters": 2300,
  "completedObjectiveIds": ["uuid"],
  "visitedStopIds": ["uuid"]
}
```

→ `RouteOption`, labelled `Rerouted`. It runs from `origin`, through the quest objectives not yet done
(by the server's record or by `completedObjectiveIds`) and the requested stops still ahead of
`progressMeters` and not in `visitedStopIds`, to where route `{id}` ended: the start for a loop, the
destination otherwise. A loop with nothing left to visit is rejoined part-way round rather than cut
short. It is one engine request with no alternatives, no place import and no request reading, so it
answers in about a second; it never becomes a quest's `suggestedRouteId`. `502 ROUTE_GENERATION_FAILED`
when no way can be found, `404` for a route that is not the caller's.

- `GET /routes/{id}` → `RouteOption`
- `GET /routes/{id}/package` → `RoutePackage` (everything needed offline):

```json
{"route": RouteOption, "quest": Quest|null, "pois": [RoutePOI], "mapRegion": {"minLat":..,"minLon":..,"maxLat":..,"maxLon":..}, "generatedAt": "..."}
```

With `effort_combat` on, fetching the package of the route chosen to ride places one creature at a
real place beside its far half (from halfway to nine tenths of the way), once per route, unless one is
already waiting there. Fetch the world objects after the package to see it.

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
  "createdAt": "...",
  "loadout": {"version": 1, "characterClass": "EXPLORER", "overallLevel": 8, "classLevel": 6,
              "damagePct": {"GROUND": 0.3}, "runeThreshold": 0.22, "runeReachMeters": 1000,
              "coinPct": {}, "xpPct": {}},
  "quarryId": "uuid|null"
}
```

`loadout` (0.6.1) is the character sheet frozen when the ride was created; the
fight is judged against it (docs/COMBAT.md). `Character.sheet` carries the
same shape, for an outing started offline. `quarryId` is the world object the
outing was planned for.

- `POST /rides` `{"clientRideId": "uuid", "startedAt": "...", "questId": null, "bikeId": null, "routeId": null, "quarryId": null, "title": null}` → `Ride`. Duplicate `clientRideId` returns the existing ride (idempotent). `title` (≤120 chars) names a custom adventure — a ride planned from a free-text request rather than a quest; quest rides are named by the quest.
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
  "objectiveEvents": [{"objectiveId": "uuid", "occurredAt": "...", "latitude": 51.49, "longitude": -0.04, "note": null}],
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
  "levelUps": [...], "abilitiesUnlocked": [...], "titlesUnlocked": ["Early Riser"],
  "acAwarded": 96, "acBreakdown": [{"kind": "RIDE_DISTANCE", "ac": 16, "detail": {...}}], "walletBalance": 410,
  "worldObjects": {
    "claimed": [{"id": "uuid", "kind": "COLLECTABLE", "name": "Raido (Old Runes)", "tier": 1, "rewardAC": 10, "method": "PASS",
                 "setId": "RUNES", "piece": "Raido", "setName": "Old Runes", "setSize": 6, "setOwned": 3}],
    "missed": [{"id": "uuid", "kind": "MONSTER", "name": "Fen Troll", "reason": "UNBEATEN", "expiresAt": "...",
                "attempt": {"method": "PACE", "paceSecPerKm": 138.2, "targetSecPerKm": 130.0, "windowMeters": 1000.0, "progress": 0.941}}],
    "setsCompleted": [{"id": "COINS", "name": "Milled Coins", "bonusAC": 50}]
  },
  "streak": {"days": 6, "longest": 9, "extended": true, "milestone": null, "bonusAC": 30},
  "flags": []
}
```

What a ride pays:

- **XP** (`xpBreakdown[].source`): `QUEST_COMPLETED`, `STORY_QUEST_COMPLETED`, `STORY_ARC_COMPLETED`,
  `QUEST_OBJECTIVE_COMPLETED`, `NEW_AREA_EXPLORED`, `NEW_ROAD_EXPLORED`, `DISCOVERY_FOUND`,
  `LONG_DISTANCE_ADVENTURE`, `CLIMB_COMPLETED`, `CHEST_OPENED`, `COLLECTABLE_FOUND`, `MONSTER_BEATEN`
  (a bounty half as much again), `SET_COMPLETED`, `KNOWN_GROUND`, `CLASS_BONUS`. `KNOWN_GROUND` is the
  distance not on new roads: 2 XP a kilometre for a ride, more on foot, from 1 km, capped at 60. A ride on
  roads already ridden is never worth nothing, and a new kilometre is always worth ten times a known one.
- **Coins** (`acBreakdown[].kind`): `RIDE_DISTANCE` at the activity's own rate (ride 2, run 5, walk 4 a
  kilometre), `NEW_CELLS`, `QUEST_COMPLETED`, `CHEST_OPENED`, `COLLECTABLE`, `MONSTER_SLAIN`, `BOUNTY`,
  `STREAK`, `SET_COMPLETED` (the piece that completes a set), `STORY_ARC` (the last step of an arc).
- `missed[].attempt` is the nearest of the monster's ways to being satisfied: for `PACE` the pace given
  and wanted, for `CLIMB` `gainMeters` and `targetGainMeters`, for `EXPLORE` `cells` and `targetCells`.
  `progress` is 1 at the target. A note not written or a shape not drawn has no attempt.
- `questCompletion.storyProgress`, for a quest that is a step of an arc:
  `{"arcSlug", "arcTitle", "stepTitle", "stepsDone", "stepsTotal", "arcCompleted", "nextTitle", "reward"}`.
  On the last step `reward` is `{"title", "ac"}`: the title is set on the character and listed in
  `titlesUnlocked`, the purse is the `STORY_ARC` coin line. A title earned this way is kept until a
  level brings a new one. Since 0.6.2 the ending is paid once per arc (`story.settle_arc`), on a
  ride, by a chest opened by hand, or by `POST /quests/{id}/complete`, and `reward` is null on
  any later completion of the same arc.
- `entry` (0.6.2): two to five sentences about the outing, composed from its facts by seed
  (`app/chronicle/compose.py`); null for an outing under 300 m.
- `weekNotice` (0.6.2): the week's notice when this outing met it and paid it; null otherwise.
- `codexFirsts` (0.6.2): `[{"speciesId", "name", "metAs"}]`, creatures seen off or loosened for
  the first time on this outing, for the reckoning's codex stamp.

- `GET /rides` paginated, newest first. `GET /rides/{id}`. `GET /rides/{id}/geometry` → `{"coordinates": [...], "encodedPolyline": "..."}`.
- `PATCH /rides/{id}` `{"visibility": "FRIENDS", "title": "...", "notes": "..."}`
- `DELETE /rides/{id}` — discards the ride; it leaves the journal and the stats (XP already awarded stays)
- `RideOut` carries where its Strava upload stands: `stravaUploadStatus` (`QUEUED` /
  `UPLOADED` / `FAILED` / null when never sent), `stravaActivityId` (set once Strava has
  made the activity; `UPLOADED` without one means Strava has the file and is still
  processing it) and `stravaError` (Strava's own message when it failed). A rider whose
  `stravaUploadMode` is `AUTO` and who is connected has the ride uploaded right after it
  is processed; `ASK` is asked in the app on the ride summary; `POST
  /integrations/strava/upload/{ride_id}` sends or re-sends it either way.

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

- `GET /journal/adventures` → paginated `AdventureEntry` (`{ride, quest, xpAwarded, discoveries, newTerritoryMeters, photos, notes, entry}`); `entry` (0.6.2) is the outing's written lines, null before 0.6.2
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
- `GET /config` → `{"featureFlags": {...}, "h3Resolution": 9, "levels": {"max": 50, "maxClass": 50}, "environment": "development", "combat": {...}}`. `combat` (0.6.1) holds the fight's constants from `world_objects.json`; see `docs/COMBAT.md`. Flags added since 0.6.0: `codex` (on), `effort_combat` (off until ridden), `ink_fog` (0.7.0, off: the World tab's fog as one ink wash with a frontier chevron; the Journal's map card draws the wash regardless). An objective event may carry `note` (0.7.0): the note written for a `WRITE_NOTE` or an Ansuz `INSCRIBE_RUNE`, which the server judges by.
