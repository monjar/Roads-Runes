"""PostGIS DDL shared by the Alembic migration and the PostgreSQL test fixture.

Location-bearing tables keep plain latitude/longitude columns for ORM
portability; on PostgreSQL we add a generated geography point plus a GiST
index, and a linestring for routes maintained by trigger.
"""

from __future__ import annotations

from sqlalchemy import text
from sqlalchemy.engine import Connection

SPATIAL_TABLES = ("discoveries", "user_exploration_cells", "quest_instances", "quest_objectives", "ride_points")

ROUTE_GEOM_FUNCTION = """
CREATE OR REPLACE FUNCTION routes_set_geom() RETURNS trigger AS $$
BEGIN
  IF jsonb_array_length(NEW.coordinates::jsonb) >= 2 THEN
    NEW.geom := ST_SetSRID(ST_MakeLine(ARRAY(
      SELECT ST_MakePoint((c->>0)::float8, (c->>1)::float8)
      FROM jsonb_array_elements(NEW.coordinates::jsonb) AS c
    )), 4326)::geography;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql
"""


def postgis_statements() -> list[str]:
    statements = ["CREATE EXTENSION IF NOT EXISTS postgis", 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp"']
    for table in SPATIAL_TABLES:
        statements.append(
            f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS geog geography(Point, 4326) "
            "GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography) STORED"
        )
        statements.append(f"CREATE INDEX IF NOT EXISTS ix_{table}_geog ON {table} USING GIST (geog)")
    statements += [
        "ALTER TABLE routes ADD COLUMN IF NOT EXISTS geom geography(LineString, 4326)",
        "CREATE INDEX IF NOT EXISTS ix_routes_geom ON routes USING GIST (geom)",
        ROUTE_GEOM_FUNCTION,
        "DROP TRIGGER IF EXISTS trg_routes_geom ON routes",
        "CREATE TRIGGER trg_routes_geom BEFORE INSERT OR UPDATE OF coordinates ON routes "
        "FOR EACH ROW EXECUTE FUNCTION routes_set_geom()",
    ]
    return statements


def apply_postgis(connection: Connection) -> None:
    """Apply the PostGIS additions on an existing schema (idempotent)."""
    for statement in postgis_statements():
        connection.execute(text(statement))
