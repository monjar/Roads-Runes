# Roads & Runes backend

FastAPI modular monolith. PostgreSQL + PostGIS for data, Redis for jobs and
rate limits, GraphHopper for routing. See `../docs/ARCHITECTURE.md`.

## Run locally

```bash
cd backend
python3.11 -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"
cp .env.example .env            # defaults point at the docker-compose services
docker compose -f ../infra/docker-compose.yml up -d db redis
alembic upgrade head
uvicorn app.main:app --reload
```

Open http://localhost:8000/docs. With `DEV_AUTH_ENABLED=true` you can sign in
with `POST /api/v1/auth/dev {"subject": "me"}` instead of Sign in with Apple.

### Seed data for the app

```bash
python scripts/seed_dev.py                     # subject rider-1 around 51.49,-0.04 (Rotherhithe)
python scripts/seed_dev.py --subject me --lat 51.45 --lon -0.10 --count 8
```

Creates the rider the iPhone app signs in as through "Developer sign in"
(subject `rider-1` by default), an Explorer with a gravel bike, ~30 curated
discoveries around south-east London when none exist near the location, and
tops available quests up to `--count` from the templates. Safe to re-run.
`make seed` does the same from the repo root.

Routing works anywhere: GraphHopper (custom bike models) inside the extract it
imported, Valhalla everywhere else (`ROUTING_ENGINE=auto`; see
`../routing/README.md`). With neither reachable the API logs a warning and
serves *synthetic* routes (geometrically plausible loops) so the rest of the
loop is testable; production refuses to start in that state. Start GraphHopper
with `docker compose --profile routing up graphhopper` after downloading an OSM
extract (`../infra/scripts/download-osm.sh`); restart the API once it is healthy.

Discoveries, the places quests and route stops are built from, are imported
from OpenStreetMap through Overpass the first time an area is used
(`app/discoveries/osm_import.py`). The 0.1° tile under the rider is fetched
before quests are generated there (for up to 15 s), its eight neighbours follow
in the background, and `poi_import_areas` records every tile so it is fetched
once; a failed tile is retried after 15 minutes. `POI_IMPORT_ENABLED` and
`OVERPASS_URLS` (tried in order) control it; the tests turn it off.

## Tests

```bash
pytest -m "not integration"   # SQLite + synthetic router; runs anywhere
# Full suite on PostGIS. The fixtures DROP AND RECREATE every table, so point it at a
# throwaway database, never the dev one (docker exec roadsandrunes-db-1 createdb -U rr roadsandrunes_test):
export TEST_DATABASE_URL=postgresql+asyncpg://rr:rr@localhost:5432/roadsandrunes_test
DATABASE_URL=$TEST_DATABASE_URL pytest
ruff check . && ruff format --check .
```

`tests/test_first_playable_journey.py` drives the whole spec §96 journey
through the HTTP API.

## Layout

```
app/
  core/         settings, errors, security, logging, geo, llm, rate limit
  db/           SQLAlchemy base, session, spatial helpers, model registry
  auth/         Sign in with Apple, JWT, refresh tokens, dev auth
  users/        profile, settings, public profile (privacy filtered)
  characters/   classes & abilities catalog (JSON), bikes, rider profile
  progression/  level & XP config (JSON), pure engine, reward service
  exploration/  H3 cell logic, fog-of-war persistence, world endpoints
  quests/       state machine, templates (JSON), deterministic generator,
                optional LLM narrative, lifecycle service
  routing/      GraphHopper client + synthetic fallback, custom models,
                elevation/surface analysis, scoring (JSON weights), POIs,
                natural-language preference parsing
  rides/        recording, validation (anti-cheat), post-ride processing job,
                journal, GPX/TCX export
  discoveries/  POIs and user discoveries
  social/       friends, feed, parties
  integrations/ Strava OAuth + upload
  notifications/device tokens, push (APNs behind a flag)
  jobs/         queue abstraction (inline / Redis) and worker
  api/v1/       router assembly
alembic/        migrations (PostGIS columns + indexes live here)
scripts/        gen_levels.py, seed_discoveries.py, seed_dev.py
```

## Environment variables

See `.env.example`. `FEATURE_FLAGS` is a comma list (`story_quests,!fog_of_war`).
Never use production credentials locally.
