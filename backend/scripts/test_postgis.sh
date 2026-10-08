#!/usr/bin/env bash
# The deploy's PostGIS job, run here before a push: a fresh database, every
# migration up, one down and up again, then the full suite with the integration
# tests. The unit suite runs on SQLite, which neither holds a string to its
# column's width nor rolls a savepoint back the way Postgres does; both have
# stopped a deploy that the unit suite passed.
#
#   make backend-test-pg            # or: scripts/test_postgis.sh -k lamp
#
# Needs the local stack's database container up (docker compose, infra/).
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER=${PG_CONTAINER:-roadsandrunes-db-1}
DB="rr_suite_$$"
BASE=${PG_BASE_URL:-postgresql+asyncpg://rr:rr@localhost:5432}

psql_in() { docker exec "$CONTAINER" sh -c "psql -U \"\$POSTGRES_USER\" -d $1 -qc \"$2\""; }
psql_in postgres "CREATE DATABASE $DB"
trap 'psql_in postgres "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1 || true' EXIT
psql_in "$DB" "CREATE EXTENSION IF NOT EXISTS postgis"

export ENVIRONMENT=test DEV_AUTH_ENABLED=true JWT_SECRET=ci
export DATABASE_URL="$BASE/$DB" TEST_DATABASE_URL="$BASE/$DB"
.venv/bin/alembic upgrade head
.venv/bin/alembic downgrade -1
.venv/bin/alembic upgrade head
.venv/bin/pytest -q "$@"
