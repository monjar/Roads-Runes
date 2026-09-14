"""Days in a row with an outing (economy/streaks.py).

Revision ID: 0006
Revises: 0005
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if "user_streaks" in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "user_streaks",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("current_days", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("longest_days", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_activity_date", sa.Date(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("user_id", name="uq_user_streaks_user_id"),
    )
    op.create_index("ix_user_streaks_user_id", "user_streaks", ["user_id"])


def downgrade() -> None:
    op.drop_table("user_streaks")
