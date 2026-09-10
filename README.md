# Roads & Runes

A real-world cycling exploration RPG. The map is the real world, your bicycle
is how you explore it. iPhone + Apple Watch client in Swift; Python/FastAPI
backend on PostgreSQL/PostGIS with GraphHopper routing.

> "There's a quest over there, and I've never ridden through that area."

## Screens

The UI follows the Claude Design project *Cycling Companion*
(`docs/design/`): cream ground, terracotta for the route and the primary
action, sage for the rider and success, class hues for emblems and markers
only, Caprasimo for titles and Figtree for numbers. The renders below are
drawn from that design with the app's tokens and fonts (all of them, with
the design option each implements, in [docs/SCREENS.md](docs/SCREENS.md));
they are not device captures yet.

| World (9a) | Quest detail (10a) | Navigation (12a) | Adventure complete (13b) |
|---|---|---|---|
| ![World](docs/screenshots/02-world.png) | ![Quest detail](docs/screenshots/04-quest-detail.png) | ![Navigation](docs/screenshots/06-navigation.png) | ![Adventure complete](docs/screenshots/07-adventure-complete.png) |

| Three ways to ride it (2a) | Character (11b) | Journal (14a) | Objective complete (12b) |
|---|---|---|---|
| ![Routes](docs/screenshots/05-routes.png) | ![Character](docs/screenshots/09-character.png) | ![Journal](docs/screenshots/08-journal.png) | ![Objective complete](docs/screenshots/10-objective-complete.png) |

| Watch navigation | Watch quest | Watch ride | Watch objective complete |
|---|---|---|---|
| ![Watch navigation](docs/screenshots/w1-watch-navigation.png) | ![Watch quest](docs/screenshots/w2-watch-quest.png) | ![Watch stats](docs/screenshots/w3-watch-stats.png) | ![Watch objective](docs/screenshots/w4-watch-objective-complete.png) |

## Repository

```
backend/   FastAPI modular monolith (auth, characters, progression, quests,
           routing, exploration, rides, discoveries, social, integrations)
ios/       Xcode project (XcodeGen) — iPhone app, Watch app, and the
           pure-Swift RoadsAndRunesCore package
docs/      architecture, API contract, subsystem docs, the Claude Design
           export (docs/design) and rendered screens
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
| 1 Exploration | sign in, world, H3 fog, ride recording, cells | backend done and tested; iOS written, needs device validation |
| 2 Explorer RPG | XP, levels, 13+ templates, generation, completion, abilities | backend done; iOS written |
| 3 Routing | GraphHopper, alternatives, scoring, elevation, surface, POIs, packages | done (needs a GraphHopper instance + field validation) |
| 4 Navigation | turn-by-turn, off-route, progress, crash recovery | client logic written, untested on a bike |
| 5 Watch | workout, turns, quest, stats, haptics, Always-On | written, untested on hardware |
| 6 Other classes | Wizard/Warrior/Scribe | catalog + one template each, behind flags |
| 7 Social | friends, feed, parties | backend done, flag-gated; minimal UI |
| 8 Integrations | Strava OAuth/upload, GPX/TCX, HealthKit | backend done; HealthKit client written |
| 9 Living world | story arcs, regions, events | schema only |

Verification so far: the backend suite (unit + HTTP end-to-end) passes on
SQLite and, in CI, against PostGIS after the Alembic migration; the
`RoadsAndRunesCore` Swift package builds and its tests pass on macOS in CI;
the iPhone app and its embedded Watch app compile in CI (Xcode 16, unsigned
simulator build). The apps have not been run on a device or simulator yet:
the field tests in spec §80 are still open.

See `docs/ARCHITECTURE.md` for the design and `docs/API.md` for the contract.
