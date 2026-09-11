"""Tiles whose OpenStreetMap places have been imported (discoveries/osm_import.py).

Revision ID: 0002
Revises: 0001
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 0001 builds every table from the current models, so a fresh database already has it.
    if "poi_import_areas" in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "poi_import_areas",
        sa.Column("key", sa.String(24), primary_key=True),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("poi_count", sa.Integer(), nullable=False),
        sa.Column("imported_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("poi_import_areas")
