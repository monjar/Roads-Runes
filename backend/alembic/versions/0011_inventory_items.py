"""Gear and consumables: the items a character has had, and what the loadout
wears and holds (docs/ROADMAP.md, 0.7.2).

No data is moved: the table starts empty, the loadout columns start empty, and
the levels already reached are paid on the first look at the inventory.

Revision ID: 0011
Revises: 0010
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    if "inventory_items" not in set(inspector.get_table_names()):
        op.create_table(
            "inventory_items",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("character_id", sa.Uuid(), sa.ForeignKey("characters.id", ondelete="CASCADE"), nullable=False),
            sa.Column("item_id", sa.String(40), nullable=False),
            sa.Column("rarity", sa.String(12), nullable=False),
            sa.Column("source", sa.String(20), nullable=False),
            sa.Column("source_key", sa.String(160), nullable=False),
            sa.Column("ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="SET NULL"), nullable=True),
            sa.Column("acquired_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("sold_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("sold_for", sa.Integer(), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.UniqueConstraint("user_id", "source_key", name="uq_inventory_items_user_id_source_key"),
        )
        op.create_index("ix_inventory_items_user_id", "inventory_items", ["user_id"])
        op.create_index("ix_inventory_items_character_id", "inventory_items", ["character_id"])
    columns = {c["name"] for c in inspector.get_columns("loadouts")}
    if "gear" not in columns:
        op.add_column("loadouts", sa.Column("gear", JSON, nullable=False, server_default=sa.text("'{}'")))
    if "consumables" not in columns:
        op.add_column("loadouts", sa.Column("consumables", JSON, nullable=False, server_default=sa.text("'{}'")))
    if "finishes_since_rare" not in columns:
        op.add_column(
            "loadouts", sa.Column("finishes_since_rare", sa.Integer(), nullable=False, server_default="0")
        )


def downgrade() -> None:
    op.drop_column("loadouts", "finishes_since_rare")
    op.drop_column("loadouts", "consumables")
    op.drop_column("loadouts", "gear")
    op.drop_index("ix_inventory_items_character_id", table_name="inventory_items")
    op.drop_index("ix_inventory_items_user_id", table_name="inventory_items")
    op.drop_table("inventory_items")
