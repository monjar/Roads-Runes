"""Feature flag overrides saved on /admin (app/admin/flags.py): one row per flag switched
over what the code and FEATURE_FLAGS say.

No data is moved: the table starts empty, so every flag resolves as it did before.

Revision ID: 0015
Revises: 0014
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0015"
down_revision = "0014"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if "feature_flag_overrides" in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "feature_flag_overrides",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("name", sa.String(64), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("note", sa.String(200), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.UniqueConstraint("name", name="uq_feature_flag_overrides_name"),
    )


def downgrade() -> None:
    if "feature_flag_overrides" in sa.inspect(op.get_bind()).get_table_names():
        op.drop_table("feature_flag_overrides")
