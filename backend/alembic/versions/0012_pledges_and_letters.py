"""Between rides: the pledge, letters to your future self, and the day a journey
began on the phone's calendar (docs/ROADMAP.md, 0.7.3).

No data is moved: both tables start empty and `rides.local_date` starts null (a
journey without it reads its day from `started_at`).

Revision ID: 0012
Revises: 0011
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    inspector = sa.inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    if "pledges" not in tables:
        op.create_table(
            "pledges",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("day", sa.Date(), nullable=False),
            sa.Column("target_kind", sa.String(12), nullable=False),
            sa.Column("target_id", sa.Uuid(), nullable=False),
            sa.Column("target_name", sa.String(160), nullable=False),
            sa.Column("remind_at", sa.String(5), nullable=True),
            sa.Column("status", sa.String(10), nullable=False),
            sa.Column("kept_ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="SET NULL"), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.UniqueConstraint("user_id", "day", name="uq_pledges_user_id_day"),
        )
        op.create_index("ix_pledges_user_id", "pledges", ["user_id"])
    if "letters" not in tables:
        op.create_table(
            "letters",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("latitude", sa.Float(), nullable=False),
            sa.Column("longitude", sa.Float(), nullable=False),
            sa.Column("text", sa.String(140), nullable=False),
            sa.Column("place_name", sa.String(160), nullable=True),
            sa.Column("written_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("shown_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("shown_ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="SET NULL"), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        )
        op.create_index("ix_letters_user_id", "letters", ["user_id"])
    if "local_date" not in {c["name"] for c in inspector.get_columns("rides")}:
        op.add_column("rides", sa.Column("local_date", sa.Date(), nullable=True))


def downgrade() -> None:
    op.drop_column("rides", "local_date")
    op.drop_index("ix_letters_user_id", table_name="letters")
    op.drop_table("letters")
    op.drop_index("ix_pledges_user_id", table_name="pledges")
    op.drop_table("pledges")
