"""Initial schema: all core tables plus PostGIS geography columns.

Revision ID: 0001
Revises:
"""

from __future__ import annotations

from alembic import op
from sqlalchemy import text

from app.db.models import Base
from app.db.postgis import postgis_statements

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    op.execute(text("CREATE EXTENSION IF NOT EXISTS postgis"))
    Base.metadata.create_all(bind)
    for statement in postgis_statements():
        op.execute(text(statement))


def downgrade() -> None:
    op.execute(text("DROP TRIGGER IF EXISTS trg_routes_geom ON routes"))
    op.execute(text("DROP FUNCTION IF EXISTS routes_set_geom"))
    bind = op.get_bind()
    Base.metadata.drop_all(bind)
