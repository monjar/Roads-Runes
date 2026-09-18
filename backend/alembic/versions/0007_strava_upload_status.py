"""Where a ride's Strava upload stands (integrations/strava.py).

Revision ID: 0007
Revises: 0006
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    columns = {c["name"] for c in sa.inspect(op.get_bind()).get_columns("rides")}
    if "strava_upload_status" not in columns:
        op.add_column("rides", sa.Column("strava_upload_status", sa.String(12), nullable=True))
    if "strava_error" not in columns:
        op.add_column("rides", sa.Column("strava_error", sa.String(300), nullable=True))


def downgrade() -> None:
    op.drop_column("rides", "strava_error")
    op.drop_column("rides", "strava_upload_status")
