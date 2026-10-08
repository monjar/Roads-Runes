"""The character sheet frozen onto a ride at its start (characters/sheet.py), and
the thing the outing was planned for (its quarry).

Revision ID: 0008
Revises: 0007
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def upgrade() -> None:
    columns = {c["name"] for c in sa.inspect(op.get_bind()).get_columns("rides")}
    if "loadout_snapshot" not in columns:
        op.add_column("rides", sa.Column("loadout_snapshot", JSON, nullable=True))
    if "quarry_id" not in columns:
        op.add_column("rides", sa.Column("quarry_id", sa.Uuid(), nullable=True))


def downgrade() -> None:
    op.drop_column("rides", "quarry_id")
    op.drop_column("rides", "loadout_snapshot")
