"""Rides, quests, routes and the rider profile learn how the player moves (core/activity.py).

Revision ID: 0004
Revises: 0003
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def _add(inspector: sa.Inspector, table: str, column: sa.Column) -> None:
    # 0001 builds every table from the current models, so a fresh database has these.
    if column.name not in {c["name"] for c in inspector.get_columns(table)}:
        op.add_column(table, column)


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    for table in ("rides", "quest_instances", "routes"):
        _add(inspector, table, sa.Column("activity", sa.String(8), nullable=False, server_default="RIDE"))
    _add(inspector, "rider_profiles", sa.Column("default_activity", sa.String(8), nullable=False, server_default="RIDE"))
    _add(inspector, "rider_profiles", sa.Column("run_distance_km", sa.Float(), nullable=False, server_default="8"))
    _add(inspector, "rider_profiles", sa.Column("walk_distance_km", sa.Float(), nullable=False, server_default="5"))


def downgrade() -> None:
    for table in ("rides", "quest_instances", "routes"):
        op.drop_column(table, "activity")
    op.drop_column("rider_profiles", "walk_distance_km")
    op.drop_column("rider_profiles", "run_distance_km")
    op.drop_column("rider_profiles", "default_activity")
