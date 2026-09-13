"""Active Coins (economy/models.py) and per-class progress on the character.

Revision ID: 0003
Revises: 0002
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")


def upgrade() -> None:
    # 0001 builds every table from the current models, so a fresh database has all of
    # this already; each object is checked on its own.
    inspector = sa.inspect(op.get_bind())
    tables = inspector.get_table_names()
    if "wallets" not in tables:
        op.create_table(
            "wallets",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("balance", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("lifetime_earned", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.UniqueConstraint("user_id", name="uq_wallets_user_id"),
        )
        op.create_index("ix_wallets_user_id", "wallets", ["user_id"])
    if "wallet_transactions" not in tables:
        op.create_table(
            "wallet_transactions",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("wallet_id", sa.Uuid(), sa.ForeignKey("wallets.id", ondelete="CASCADE"), nullable=False),
            sa.Column("amount", sa.Integer(), nullable=False),
            sa.Column("kind", sa.String(32), nullable=False),
            sa.Column("ride_id", sa.Uuid(), sa.ForeignKey("rides.id", ondelete="SET NULL"), nullable=True),
            sa.Column("quest_id", sa.Uuid(), sa.ForeignKey("quest_instances.id", ondelete="SET NULL"), nullable=True),
            sa.Column("object_id", sa.Uuid(), nullable=True),
            sa.Column("payload", JSON, nullable=False, server_default="{}"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        )
        op.create_index("ix_wallet_transactions_user_id", "wallet_transactions", ["user_id"])
        op.create_index("ix_wallet_transactions_wallet_id", "wallet_transactions", ["wallet_id"])
        op.create_index("ix_wallet_transactions_ride_id", "wallet_transactions", ["ride_id"])
        op.create_index("ix_wallet_transactions_user_created", "wallet_transactions", ["user_id", "created_at"])
    columns = {c["name"] for c in inspector.get_columns("characters")}
    if "class_progress" not in columns:
        op.add_column("characters", sa.Column("class_progress", JSON, nullable=False, server_default="{}"))
    if "class_changes" not in columns:
        op.add_column("characters", sa.Column("class_changes", sa.Integer(), nullable=False, server_default="0"))
    if "class_changed_at" not in columns:
        op.add_column("characters", sa.Column("class_changed_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("characters", "class_changed_at")
    op.drop_column("characters", "class_changes")
    op.drop_column("characters", "class_progress")
    op.drop_table("wallet_transactions")
    op.drop_table("wallets")
