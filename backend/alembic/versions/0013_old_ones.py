"""Legends: the old ones, one great creature at a time (docs/ROADMAP.md, 0.8.0).

No data is moved: the table starts empty. Lairs and buried treasure are world
objects (kind LAIR, status HIDDEN), and both fit the columns world_objects has.

Revision ID: 0013
Revises: 0012
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "old_ones" in set(inspector.get_table_names()):
        return
    op.create_table(
        "old_ones",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("character_id", sa.Uuid(), sa.ForeignKey("characters.id", ondelete="CASCADE"), nullable=False),
        sa.Column("species_id", sa.String(30), nullable=False),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("latitude", sa.Float(), nullable=False),
        sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("anchor_name", sa.String(160), nullable=True),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("phase", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("phase_hold_max", sa.Integer(), nullable=False, server_default="500"),
        sa.Column("phase_hold_left", sa.Integer(), nullable=False, server_default="500"),
        sa.Column("wounds", JSON, nullable=False, server_default=sa.text("'{}'")),
        sa.Column("moved", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("woke_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_hit_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_phase_break_day", sa.Date(), nullable=True),
        sa.Column("defeated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("payload", JSON, nullable=False, server_default=sa.text("'{}'")),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_old_ones_user_id", "old_ones", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_old_ones_user_id", table_name="old_ones")
    op.drop_table("old_ones")
