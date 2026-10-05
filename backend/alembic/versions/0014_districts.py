"""Districts (docs/ROADMAP.md, 0.9.0 "The parish"): `regions` from OpenStreetMap place
nodes, `user_regions` for how far each player has explored them, and the look worn
(route ink, marker and crest frames) on `loadouts.look`. Cosmetics themselves are
`inventory_items` rows with prefixed ids, so no table of their own.

No data is moved: the tables start empty and the column starts null (the defaults).

Revision ID: 0014
Revises: 0013
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def _timestamps() -> list[sa.Column]:
    return [
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    ]


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    if "regions" not in tables:
        op.create_table(
            "regions",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("osm_id", sa.String(32), nullable=False),
            sa.Column("name", sa.String(120), nullable=False),
            sa.Column("kind", sa.String(20), nullable=False),
            sa.Column("latitude", sa.Float(), nullable=False),
            sa.Column("longitude", sa.Float(), nullable=False),
            sa.Column("tile", sa.String(32), nullable=False),
            sa.Column("way_cells", JSON, nullable=True),
            sa.Column("way_cells_fetched_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("epithet", sa.String(40), nullable=True),
            sa.Column("place_counts", JSON, nullable=False, server_default=sa.text("'{}'")),
            *_timestamps(),
            sa.UniqueConstraint("osm_id", name="uq_regions_osm_id"),
        )
        op.create_index("ix_regions_tile", "regions", ["tile"])
    if "user_regions" not in tables:
        op.create_table(
            "user_regions",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("region_id", sa.Uuid(), sa.ForeignKey("regions.id", ondelete="CASCADE"), nullable=False),
            sa.Column("explored_cells", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("way_cells_explored", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("first_passed_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("last_passed_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("yours_since", sa.DateTime(timezone=True), nullable=True),
            sa.Column("last_paid_week", sa.String(10), nullable=True),
            *_timestamps(),
            sa.UniqueConstraint("user_id", "region_id", name="uq_user_regions_user_id"),
        )
        op.create_index("ix_user_regions_user_id", "user_regions", ["user_id"])
        op.create_index("ix_user_regions_region_id", "user_regions", ["region_id"])
    if "loadouts" in tables and "look" not in {c["name"] for c in inspector.get_columns("loadouts")}:
        op.add_column("loadouts", sa.Column("look", JSON, nullable=True))


def downgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    if "loadouts" in tables and "look" in {c["name"] for c in inspector.get_columns("loadouts")}:
        with op.batch_alter_table("loadouts") as batch:
            batch.drop_column("look")
    if "user_regions" in tables:
        op.drop_index("ix_user_regions_region_id", table_name="user_regions")
        op.drop_index("ix_user_regions_user_id", table_name="user_regions")
        op.drop_table("user_regions")
    if "regions" in tables:
        op.drop_index("ix_regions_tile", table_name="regions")
        op.drop_table("regions")
