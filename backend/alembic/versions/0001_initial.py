"""Initial schema: all core tables plus PostGIS geography columns.

Revision ID: 0001
Revises:
"""
from __future__ import annotations

from alembic import op
from sqlalchemy import text

from app.db.models import Base

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

# Tables with latitude/longitude that get a generated geography column + GiST index.
SPATIAL_TABLES = ("discoveries", "user_exploration_cells", "quest_instances", "quest_objectives", "ride_points")


def upgrade() -> None:
    op.execute(text("CREATE EXTENSION IF NOT EXISTS postgis"))
    op.execute(text("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\""))
    bind = op.get_bind()
    Base.metadata.create_all(bind)
    for table in SPATIAL_TABLES:
        op.execute(
            text(
                f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS geog geography(Point, 4326) "
                "GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography) STORED"
            )
        )
        op.execute(text(f"CREATE INDEX IF NOT EXISTS ix_{table}_geog ON {table} USING GIST (geog)"))
    # Route corridor searches: linestring geometry built from the JSON coordinates by trigger.
    op.execute(text("ALTER TABLE routes ADD COLUMN IF NOT EXISTS geom geography(LineString, 4326)"))
    op.execute(text("CREATE INDEX IF NOT EXISTS ix_routes_geom ON routes USING GIST (geom)"))
    op.execute(
        text(
            """
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
        )
    )
    op.execute(text("DROP TRIGGER IF EXISTS trg_routes_geom ON routes"))
    op.execute(text("CREATE TRIGGER trg_routes_geom BEFORE INSERT OR UPDATE OF coordinates ON routes FOR EACH ROW EXECUTE FUNCTION routes_set_geom()"))


def downgrade() -> None:
    op.execute(text("DROP TRIGGER IF EXISTS trg_routes_geom ON routes"))
    op.execute(text("DROP FUNCTION IF EXISTS routes_set_geom"))
    bind = op.get_bind()
    Base.metadata.drop_all(bind)
