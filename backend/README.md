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

Without GraphHopper running the API logs a warning and serves *synthetic*
routes (geometrically plausible loops) so the rest of the loop is testable.
Production refuses to start in that state. Start the real engine with
`docker compose --profile routing up graphhopper` after downloading an OSM
extract (`../infra/scripts/download-osm.sh`).

## Tests

```bash
pytest -m "not integration"   # SQLite + synthetic router; runs anywhere
pytest -m integration         # needs DATABASE_URL pointing at PostGIS
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
scripts/        gen_levels.py, seed_discoveries.py
```

## Environment variables

See `.env.example`. `FEATURE_FLAGS` is a comma list (`story_quests,!fog_of_war`).
Never use production credentials locally.
