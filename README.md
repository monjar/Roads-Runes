# Roads & Runes

A real-world cycling exploration RPG. The map is the real world, your bicycle
is how you explore it. iPhone + Apple Watch client in Swift; Python/FastAPI
backend on PostgreSQL/PostGIS with GraphHopper routing.

> "There's a quest over there, and I've never ridden through that area."

## Repository

```
backend/   FastAPI modular monolith (auth, characters, progression, quests,
           routing, exploration, rides, discoveries, social, integrations)
ios/       Xcode project (XcodeGen) — iPhone app, Watch app, and the
           pure-Swift RoadsAndRunesCore package
routing/   GraphHopper configuration and bike custom models
infra/     docker-compose, environment matrix, OSM download script
docs/      product spec, architecture, API, quest/exploration/routing/watch/
           privacy documentation
```

## Quick start

```bash
make up                       # PostGIS + Redis
cp backend/.env.example backend/.env
cd backend && python3.11 -m venv .venv && . .venv/bin/activate && pip install -e ".[dev]"
alembic upgrade head && uvicorn app.main:app --reload
```

The API is at http://localhost:8000/docs. `POST /api/v1/auth/dev` signs in
without Apple credentials in development. Real routing needs GraphHopper
(`make osm && make routing`); without it development serves synthetic routes.

iOS:

```bash
brew install xcodegen
cd ios && xcodegen generate && open RoadsAndRunes.xcodeproj
```

Set `API_BASE_URL` in `ios/RoadsAndRunes/App/Config.swift` (or the Info.plist
key) to your machine's address when running on a device.

## Tests

```bash
make test                     # backend unit + API tests (SQLite, synthetic router)
cd backend && pytest -m integration   # against PostGIS (CI does this)
cd ios/Packages/RoadsAndRunesCore && swift test
```

`backend/tests/test_first_playable_journey.py` drives the spec's first
playable journey (sign in → character → quests → route → ride → XP → journal)
end to end.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 Repository | layout, CI, lint, compose, envs | done |
| 1 Exploration | sign in, world, H3 fog, ride recording, cells | backend done; iOS written, needs device validation |
| 2 Explorer RPG | XP, levels, 13+ templates, generation, completion, abilities | backend done; iOS written |
| 3 Routing | GraphHopper, alternatives, scoring, elevation, surface, POIs, packages | done (needs a GraphHopper instance + field validation) |
| 4 Navigation | turn-by-turn, off-route, progress, crash recovery | client logic written, untested on a bike |
| 5 Watch | workout, turns, quest, stats, haptics, Always-On | written, untested on hardware |
| 6 Other classes | Wizard/Warrior/Scribe | catalog + one template each, behind flags |
| 7 Social | friends, feed, parties | backend done, flag-gated; minimal UI |
| 8 Integrations | Strava OAuth/upload, GPX/TCX, HealthKit | backend done; HealthKit client written |
| 9 Living world | story arcs, regions, events | schema only |

No Swift toolchain was available while this was written: the iOS/watchOS
code has not been compiled. Expect a first pass of compiler fixes in Xcode
before field testing (spec §80 lists the mandatory field tests).

See `docs/ARCHITECTURE.md` for the design and `docs/API.md` for the contract.
