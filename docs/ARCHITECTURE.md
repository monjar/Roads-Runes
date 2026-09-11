# Architecture

## Principles

1. **The core loop first.** Everything serves: open app → see unexplored
   world → pick quest → ride → discover → earn → level → repeat.
2. **Server-authoritative rewards.** XP, levels, cell states and quest
   completion are computed on the backend from validated GPS traces. The
   client shows provisional progress; the server decides.
3. **Local-first rides.** The phone is the source of truth during a ride and
   never needs the network to record. The server becomes the source of truth
   after upload and processing.
4. **Configuration over constants.** Level curves, XP rules, quest templates,
   abilities, route scoring weights and feature flags are JSON/settings, not
   code.
5. **Safety is not a game system.** Abilities and LLM output influence quest
   generation, narrative and visibility only. Routing safety comes from
   GraphHopper base profiles that block motorways/trunk roads and honour bike
   access; request-time overlays can only tighten them. Outside GraphHopper's
   graph, Valhalla's bicycle costing honours OSM bicycle access (never
   motorways) but, unlike our profiles, may use trunk roads where bikes are
   legally allowed; low `use_roads` only makes them less likely.

## Backend: modular monolith

```
FastAPI  ──►  app/api/v1/router.py  ──►  module routers
                                          │
      ┌───────────┬────────────┬──────────┼──────────┬───────────┐
    auth        users      characters  progression  exploration  quests
   routing      rides     discoveries    social    integrations  notifications
                                          │
                                   services (async SQLAlchemy 2)
                                          │
      PostgreSQL + PostGIS ── Redis ── GraphHopper (region) / Valhalla (world) ── Overpass
```

Each module owns `models.py` (SQLAlchemy), `schemas.py` (pydantic, camelCase
to match the API), `service.py` (business logic) and `router.py`. Cross-module
calls go through service functions, never through routers. `app/db/models.py`
imports every model so Alembic and tests see the whole schema.

Key module notes:

* **progression** – `engine.py` is pure (XP lines → totals, XP → level);
  `service.grant()` is the only writer of XP/levels and records every grant in
  `xp_events` / `reward_events`.
* **exploration** – `cells.py` is pure H3 logic (traverse a trace, attribute
  distance per cell, bridge gaps, reconcile client-reported cells against the
  trace). `service.record_traversal()` upserts `user_exploration_cells`.
* **quests** – `state_machine.py` enforces AVAILABLE→ACCEPTED→ACTIVE→COMPLETED;
  `generator.py` is deterministic (seeded by user + day) and geographic;
  `narrative.py` optionally rewrites text with an LLM; `service.py` handles
  lifecycle and reveals target cells on the map.
* **discoveries** – `osm_import.py` imports places from OpenStreetMap
  (Overpass) per 0.1° tile the first time an area is used, so quests and route
  stops work anywhere; `poi_import_areas` records the tiles fetched.
* **routing** – `engine.py` (GraphHopper client, `RegionalRouter` sending a
  ride to GraphHopper inside its graph and to Valhalla elsewhere, synthetic
  fallback), `valhalla.py` (worldwide client: bicycle costing, loops through
  waypoints, details from `trace_attributes`),
  `custom_models.py` (preference → custom model overlay), `analysis.py`
  (elevation, climbs, surface, cycleway, traffic), `scoring.py` (weights in
  `config/scoring.json`), `pois.py` (corridor search), `preferences.py`
  (rule-based and LLM natural-language parsing).
* **rides** – `validation.py` (anti-cheat flags), `processing.py` (the
  post-ride job: validate → metrics → cells → discoveries → objectives → quest
  completion → XP → summary), `export.py` (GPX/TCX).
* **jobs** – `InlineJobQueue` (dev/test) or `RedisJobQueue` + `worker.py`.

### Spatial data

Location columns are plain `latitude`/`longitude` floats on every model so
the ORM is dialect-neutral. The Alembic migration adds a generated PostGIS
`geography(Point)` column plus a GiST index to the spatial tables and a
linestring column to `routes` (filled by trigger from the JSON coordinates).
`app/db/spatial.py` issues `ST_DWithin` on PostgreSQL and falls back to a
bounding box + haversine on SQLite, which is only used by tests.

### Request lifecycle for a ride

```
POST /rides                    → Ride(RECORDING), quest → ACTIVE
POST /rides/{id}/points        → batched RidePoints (idempotent by timestamp)
POST /rides/{id}/exploration   → client cell candidates stored on the ride
POST /quests/{id}/progress     → provisional objective completion
POST /rides/{id}/complete      → Ride(UPLOADED), job enqueued
   job process_ride            → validation, cells, discoveries, objectives,
                                 quest COMPLETED, XP granted, summary stored
GET  /rides/{id}/summary       → 202 while processing, then AdventureSummary
```

### Authentication

Sign in with Apple: the client sends the identity token; the backend verifies
it against Apple's JWKS (audience = bundle id) and maps `sub` to an internal
UUID user. Access tokens are short-lived HS256 JWTs; refresh tokens are opaque,
hashed at rest, rotated on use. `POST /auth/dev` exists only when
`DEV_AUTH_ENABLED=true` and is refused in production.

## iOS

MVVM + services. `RoadsAndRunesCore` (Swift package, no UIKit) holds models,
the API client, navigation state machine, route progress and objective
tracking, ride statistics, exploration recording and persistence formats, and
is unit-tested with `swift test`. The app target adds SwiftUI features,
CoreLocation/HealthKit/WatchConnectivity/MapLibre integrations, SwiftData
persistence and the design-system components. The design system is the
Claude Design project in `docs/design` (tokens in `Components/Theme.swift`:
cream/surface ground, terracotta for the route and primary action, sage for
the rider and success, class hues for emblems and markers, Caprasimo and
Figtree bundled as fonts); screens map to the design's option ids in
`docs/SCREENS.md`. Maps follow the ink-map rules: unexplored ground is cream
with roads ghosting through, explored cells carry a dashed ink edge, quest
waypoints are diamonds, mysteries dashed "?" circles, the rider a sage circle. The Watch target mirrors
navigation, quest and stats screens over WatchConnectivity and runs the
HealthKit workout session so it works with the phone locked. H3 on device is
the uber/h3 C library vendored as a local Swift package (`ios/Packages/H3`)
behind the `CellIndexing` protocol.

See `docs/WATCH.md`, `docs/EXPLORATION.md`, `docs/ROUTING.md`,
`docs/QUEST_SYSTEM.md`, `docs/PRIVACY.md`.

## Feature flags

Resolved in `app/core/config.py` from `FEATURE_FLAGS`; exposed via
`GET /config` and `GET /world`. Classes other than Explorer, parties, story
quests, Strava and LLM narrative ship disabled.

## Testing

* Unit: progression engine, state machine, cells, validation, analysis,
  scoring, generator.
* API/e2e: SQLite + synthetic router + inline jobs; the first-playable-journey
  test runs the entire loop over HTTP.
* Integration (CI): Alembic migration against PostGIS.
* Field tests (spec §80) are mandatory before beta and cannot be automated.

## Decisions log

* **Modular monolith, not microservices** – one deployable, module boundaries
  in code; split later if a module's load demands it.
* **H3 resolution 9** (~0.1 km², ~174 m edge) – fine enough that a street
  reveals visibly, coarse enough that a 30 km ride touches ~100–200 cells.
* **Synthetic router fallback** – lets the full loop be tested without a
  routing engine; production refuses to run with it.
* **camelCase pydantic fields** – the JSON contract is the source of truth;
  avoiding alias generators keeps `docs/API.md` and code trivially comparable.
* **Optional Anthropic LLM** via the official SDK for narrative and
  free-text route requests; deterministic fallbacks always exist.
