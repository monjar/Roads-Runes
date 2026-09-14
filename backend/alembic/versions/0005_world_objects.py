"""Chests, collectables and monsters (world_objects/models.py), and the claims a ride reports.

Revision ID: 0005
Revises: 0004
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "world_objects" not in inspector.get_table_names():
        op.create_table(
            "world_objects",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("kind", sa.String(12), nullable=False),
            sa.Column("status", sa.String(10), nullable=False, server_default="SPAWNED"),
            sa.Column("tier", sa.Integer(), nullable=False, server_default="1"),
            sa.Column("anchor_discovery_id", sa.Uuid(), sa.ForeignKey("discoveries.id", ondelete="SET NULL"), nullable=True),
            sa.Column("latitude", sa.Float(), nullable=False),
            sa.Column("longitude", sa.Float(), nullable=False),
            sa.Column("h3_index", sa.String(16), nullable=True),
            sa.Column("seed", sa.String(96), nullable=False),
            sa.Column("bounty", sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column("reward_ac", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("payload", JSON, nullable=False, server_default="{}"),
            sa.Column("spawned_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("claimed_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("claimed_ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="SET NULL"), nullable=True),
            sa.Column("claim_payload", JSON, nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.UniqueConstraint("user_id", "seed", name="uq_world_objects_user_seed"),
        )
        op.create_index("ix_world_objects_user_id", "world_objects", ["user_id"])
        op.create_index("ix_world_objects_user_status_expires", "world_objects", ["user_id", "status", "expires_at"])
        op.create_index("ix_world_objects_user_lat_lon", "world_objects", ["user_id", "latitude", "longitude"])
    if "encounter_events" not in {c["name"] for c in inspector.get_columns("rides")}:
        op.add_column("rides", sa.Column("encounter_events", JSON, nullable=False, server_default="[]"))


def downgrade() -> None:
    op.drop_column("rides", "encounter_events")
    op.drop_table("world_objects")
