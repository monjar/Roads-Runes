# Infrastructure

## Local stack

```bash
cp backend/.env.example backend/.env
docker compose -f infra/docker-compose.yml up -d db redis        # core
docker compose -f infra/docker-compose.yml up api worker         # backend (runs migrations)
```

Routing engine (optional locally, required for real navigation):

```bash
infra/scripts/download-osm.sh europe/great-britain/england/greater-london
docker compose -f infra/docker-compose.yml --profile routing up graphhopper
```

Without GraphHopper the API falls back to a synthetic router in development
and test only; production refuses to start.

## Environments

| | development | staging | production |
|---|---|---|---|
| Database | local PostGIS container | managed PostGIS, separate instance | managed PostGIS, separate instance |
| Redis | container | managed | managed |
| GraphHopper | local, one city extract | dedicated VM, region extract | dedicated VM(s), region/country extracts |
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

MVP admin operations are scripts under `backend/scripts/` (level table
generation, discovery seeding). A lightweight admin UI is a later phase.
