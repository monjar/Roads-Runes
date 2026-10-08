"""Runes held, ranked and inscribed, the cuts on the map, the inventory ledger,
deeds, and the story's remembered choices (docs/ROADMAP.md, 0.7.0).

No data is moved: every table starts empty and fills from the next outing.

Revision ID: 0010
Revises: 0009
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def _stamps() -> list[sa.Column]:
    return [
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    ]


def _owner(character: bool = True) -> list[sa.Column]:
    cols = [
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
    ]
    if character:
        cols.append(
            sa.Column("character_id", sa.Uuid(), sa.ForeignKey("characters.id", ondelete="CASCADE"), nullable=False)
        )
    return cols


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    if "rune_holdings" not in tables:
        op.create_table(
            "rune_holdings",
            *_owner(),
            sa.Column("rune_id", sa.String(20), nullable=False),
            sa.Column("rank", sa.Integer(), nullable=False, server_default="1"),
            sa.Column("shards", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("first_found_at", sa.DateTime(timezone=True), nullable=False),
            *_stamps(),
            sa.UniqueConstraint("character_id", "rune_id", name="uq_rune_holdings_character_id_rune_id"),
        )
        op.create_index("ix_rune_holdings_user_id", "rune_holdings", ["user_id"])
        op.create_index("ix_rune_holdings_character_id", "rune_holdings", ["character_id"])
    if "loadouts" not in tables:
        op.create_table(
            "loadouts",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column(
                "character_id", sa.Uuid(), sa.ForeignKey("characters.id", ondelete="CASCADE"), nullable=False, unique=True
            ),
            sa.Column("inscriptions", JSON, nullable=False, server_default=sa.text("'[]'")),
            sa.Column("repeats", sa.Integer(), nullable=False, server_default="0"),
            *_stamps(),
        )
        op.create_index("ix_loadouts_user_id", "loadouts", ["user_id"])
        op.create_index("ix_loadouts_character_id", "loadouts", ["character_id"])
    if "rune_cuts" not in tables:
        op.create_table(
            "rune_cuts",
            *_owner(character=False),
            sa.Column("ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="CASCADE"), nullable=True),
            sa.Column("rune_id", sa.String(20), nullable=False),
            sa.Column("latitude", sa.Float(), nullable=False),
            sa.Column("longitude", sa.Float(), nullable=False),
            sa.Column("woke", sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column("source", sa.String(12), nullable=False),
            sa.Column("place_name", sa.String(160), nullable=True),
            sa.Column("cut_at", sa.DateTime(timezone=True), nullable=False),
            *_stamps(),
            sa.UniqueConstraint("ride_id", "rune_id", "source", name="uq_rune_cuts_ride_id_rune_id_source"),
        )
        op.create_index("ix_rune_cuts_user_id", "rune_cuts", ["user_id"])
        op.create_index("ix_rune_cuts_ride_id", "rune_cuts", ["ride_id"])
    if "item_events" not in tables:
        op.create_table(
            "item_events",
            *_owner(character=False),
            sa.Column("kind", sa.String(20), nullable=False),
            sa.Column("key", sa.String(160), nullable=False),
            sa.Column("rune_id", sa.String(20), nullable=True),
            sa.Column("ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="SET NULL"), nullable=True),
            sa.Column("payload", JSON, nullable=False, server_default=sa.text("'{}'")),
            *_stamps(),
            sa.UniqueConstraint("user_id", "key", name="uq_item_events_user_id_key"),
        )
        op.create_index("ix_item_events_user_id", "item_events", ["user_id"])
    if "character_deeds" not in tables:
        op.create_table(
            "character_deeds",
            *_owner(),
            sa.Column("deed_id", sa.String(30), nullable=False),
            sa.Column("value", sa.Float(), nullable=False, server_default="0"),
            sa.Column("tier", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="SET NULL"), nullable=True),
            *_stamps(),
            sa.UniqueConstraint("character_id", "deed_id", name="uq_character_deeds_character_id_deed_id"),
        )
        op.create_index("ix_character_deeds_user_id", "character_deeds", ["user_id"])
        op.create_index("ix_character_deeds_character_id", "character_deeds", ["character_id"])
    columns = {c["name"] for c in inspector.get_columns("characters")}
    if "story_flags" not in columns:
        op.add_column("characters", sa.Column("story_flags", JSON, nullable=False, server_default=sa.text("'[]'")))


def downgrade() -> None:
    op.drop_column("characters", "story_flags")
    for table in ("character_deeds", "item_events", "rune_cuts", "loadouts", "rune_holdings"):
        op.drop_table(table)
