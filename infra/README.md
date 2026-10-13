# Infrastructure

## Local stack

```bash
cp backend/.env.example backend/.env
docker compose -f infra/docker-compose.yml up -d db redis        # core
docker compose -f infra/docker-compose.yml up api worker         # backend (runs migrations)
```

Routing works worldwide without anything below: outside a local GraphHopper
graph the API routes through Valhalla (the public server in development; see
`routing/README.md`). GraphHopper adds the custom bike models for one region:

```bash
infra/scripts/download-osm.sh europe/united-kingdom/england/greater-london
docker compose -f infra/docker-compose.yml --profile routing up graphhopper
```

With neither engine reachable the API falls back to a synthetic router in
development and test only; production refuses to start.

## Environments

| | development | staging | production |
|---|---|---|---|
| Database | local PostGIS container | managed PostGIS, separate instance | managed PostGIS, separate instance |
| Redis | container | managed | managed |
| GraphHopper | local, one city extract | dedicated VM, region extract | dedicated VM(s), region/country extracts |
| Valhalla (everywhere else) | public FOSSGIS server | self-hosted, planet tiles | self-hosted, planet tiles |
| Overpass (discoveries) | public mirrors | self-hosted or paid instance | self-hosted or paid instance |
| Object storage | none / local dir | bucket `rr-staging` | bucket `rr-prod` |
| Apple Sign In | `com.roadsandrunes.app.dev` | `com.roadsandrunes.app.staging` | `com.roadsandrunes.app` |
| Strava OAuth app | dev app, localhost callback | staging app | production app |
| `DEV_AUTH_ENABLED` | true | false | false (startup fails otherwise) |
| `JWT_SECRET` | any | secret manager | secret manager (startup fails on default) |
| Feature flags | all on | rollout set | rollout set |

Rules: separate databases, API keys, OAuth callbacks, object storage and
Strava configuration per environment. Never use production credentials
locally; `.env` files are git-ignored.

## Background worker

`worker` consumes the Redis list `rr:jobs` (`app/jobs/worker.py`). With
`JOB_QUEUE=inline` (development default outside compose) jobs run inside the
API process instead.

## Push notifications

APNs is disabled until certificates are provisioned (`APNS_ENABLED=true` plus
key/team/bundle settings added to `app/notifications/service.py`). Device
tokens are stored regardless so enabling it later needs no client change.

## Admin

`/admin` on the API (`backend/app/admin/`) is the developer's page: the last 7, 30
or 90 days across every rider (active and returning riders, outings, distance, new
cells, quests, coins, the world, rides stuck or failed in processing), the same as
JSON at `/admin/stats.json?days=N`, and every feature flag with an override switch.

It is off until `ADMIN_TOKEN` is set, and signs in with HTTP Basic: any user name,
the token as the password. A player's sign-in never opens it (developer sign-in lets
anyone claim any dev account, so `users.is_admin` guards nothing).

```bash
fly secrets set -a roadsandrunes ADMIN_TOKEN=$(openssl rand -hex 24)
open https://roadsandrunes.fly.dev/admin
```

A flag resolves as the code's default, then `FEATURE_FLAGS`, then an override saved
on the page (table `feature_flag_overrides`). The override needs no deploy: the
process that saves it has it at once and every other process (another machine, the
Redis worker) within 30 seconds. The app reads flags from `/api/v1/config` when it
starts. Clearing an override falls back to `FEATURE_FLAGS`.

Other admin operations are scripts under `backend/scripts/` (level table
generation, discovery seeding, `play_report.py` for one rider) and
`python -m app.jobs.reprocess` for rides that failed processing.

## Fly.io (hosted development backend)

Two apps in the `personal` org, London (`lhr`):

| app | what | config |
|---|---|---|
| `roadsandrunes-db` | PostgreSQL 16 + PostGIS, one machine with a 3 GB volume, reachable only inside the Fly network at `roadsandrunes-db.internal:5432` | `infra/fly/db/fly.toml` |
| `roadsandrunes` | the FastAPI app, public at `https://roadsandrunes.fly.dev` | `backend/fly.toml` |

```bash
fly volumes create pgdata -a roadsandrunes-db -r lhr -s 3
fly secrets set POSTGRES_PASSWORD=... -a roadsandrunes-db
cd infra/fly/db && fly deploy --ha=false

fly secrets set -a roadsandrunes \
  DATABASE_URL=postgresql+asyncpg://rr:<password>@roadsandrunes-db.internal:5432/roadsandrunes \
  JWT_SECRET=... DEV_AUTH_ENABLED=true
cd backend && fly deploy --ha=false    # the release command runs `alembic upgrade head`
```

How it differs from the local stack, deliberately:

* **No GraphHopper** (its graph needs its own machine and ~4 GB), so `ROUTING_ENGINE=valhalla`
  and every route comes from the public Valhalla server, which is fair-use only. Self-host
  Valhalla, or run GraphHopper on Fly, before real riders use it (`routing/README.md`).
* **No Redis**: `JOB_QUEUE=inline` processes a ride inside the request that completes it.
* **Developer sign-in is on**, because the iPhone build signed by a free Personal Team has no
  Sign in with Apple. Anyone with the URL can therefore create an account: this is a development
  backend. Turn it off with `fly secrets set DEV_AUTH_ENABLED=false -a roadsandrunes` once
  the app can sign in with Apple.
* **One database machine, one volume.** Fly snapshots the volume daily (5 days retained); there is
  no failover, and deploying the db app restarts the database.
* The API machine stops when idle and starts on the next request, so the first call after a quiet
  spell takes a few seconds.
