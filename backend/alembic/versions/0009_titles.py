"""Titles a character has earned, the one they chose to wear, and the story steps
waiting for better ground (docs/ROADMAP.md, 0.6.2).

The seven old level titles are renamed to degrees of being known, on the
character and in the new table, which is backfilled from each character's level
and the arc titles in their reward history. Take a database snapshot first:
`fly volumes snapshots create <volume>`.

Revision ID: 0009
Revises: 0008
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None

JSON = sa.JSON().with_variant(postgresql.JSONB(), "postgresql")

# Frozen copies of config/titles.json as it was when this was written: a
# migration must not change meaning when the config does.
RENAMED = {
    "Novice": "Passer-by",
    "Wanderer": "Familiar Face",
    "Pathfinder": "Roadwise",
    "Far Wanderer": "Journeyman",
    "Cartographer": "Waywright",
    "Worldwalker": "Old Hand",
    "Legend of the Roads": "Known to the Roads",
}
LEVEL_SLUGS = {1: "level-1", 5: "level-5", 10: "level-10", 20: "level-20", 30: "level-30", 40: "level-40", 50: "level-50"}
ARC_SLUGS = {
    "Early Riser": "arc-first-light",
    "Edgewalker": "arc-the-edge-of-the-map",
    "Stone Reader": "arc-what-the-stones-remember",
    "Ironbound": "arc-the-iron-hours",
    "Keeper of Small Things": "arc-a-record-of-small-things",
}


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    columns = {c["name"] for c in inspector.get_columns("characters")}
    if "title_pinned" not in columns:
        op.add_column("characters", sa.Column("title_pinned", sa.Boolean(), nullable=False, server_default=sa.false()))
    if "story_waiting" not in columns:
        op.add_column(
            "characters", sa.Column("story_waiting", JSON, nullable=False, server_default=sa.text("'{}'"))
        )
    if "character_titles" not in inspector.get_table_names():
        op.create_table(
            "character_titles",
            sa.Column("id", sa.Uuid(), primary_key=True),
            sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column(
                "character_id", sa.Uuid(), sa.ForeignKey("characters.id", ondelete="CASCADE"), nullable=False
            ),
            sa.Column("slug", sa.String(60), nullable=False),
            sa.Column("earned_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
            sa.UniqueConstraint("character_id", "slug", name="uq_character_titles_character_id_slug"),
        )
        op.create_index("ix_character_titles_user_id", "character_titles", ["user_id"])
        op.create_index("ix_character_titles_character_id", "character_titles", ["character_id"])

    characters = sa.table(
        "characters",
        sa.column("id", sa.Uuid()),
        sa.column("user_id", sa.Uuid()),
        sa.column("title", sa.String()),
        sa.column("overall_level", sa.Integer()),
        sa.column("created_at", sa.DateTime(timezone=True)),
    )
    titles = sa.table(
        "character_titles",
        sa.column("id", sa.Uuid()),
        sa.column("user_id", sa.Uuid()),
        sa.column("character_id", sa.Uuid()),
        sa.column("slug", sa.String()),
        sa.column("earned_at", sa.DateTime(timezone=True)),
    )
    rewards = sa.table(
        "reward_events",
        sa.column("character_id", sa.Uuid()),
        sa.column("reward_type", sa.String()),
        sa.column("payload", JSON),
        sa.column("created_at", sa.DateTime(timezone=True)),
    )
    have = {(r.character_id, r.slug) for r in bind.execute(sa.select(titles.c.character_id, titles.c.slug))}
    earned_arcs: dict[uuid.UUID, dict[str, datetime]] = {}
    for r in bind.execute(
        sa.select(rewards.c.character_id, rewards.c.payload, rewards.c.created_at).where(
            rewards.c.reward_type == "TITLE"
        )
    ):
        name = (r.payload or {}).get("title")
        if name in ARC_SLUGS:
            earned_arcs.setdefault(r.character_id, {})[ARC_SLUGS[name]] = r.created_at
    now = datetime.now(UTC)
    rows = []
    for c in bind.execute(sa.select(characters)).all():
        slugs = {slug: c.created_at or now for level, slug in LEVEL_SLUGS.items() if (c.overall_level or 1) >= level}
        slugs.update(earned_arcs.get(c.id, {}))
        if c.title in ARC_SLUGS:
            slugs.setdefault(ARC_SLUGS[c.title], now)
        for slug, at in slugs.items():
            if (c.id, slug) not in have:
                rows.append(
                    {"id": uuid.uuid4(), "user_id": c.user_id, "character_id": c.id, "slug": slug, "earned_at": at}
                )
        if c.title in RENAMED:
            bind.execute(sa.update(characters).where(characters.c.id == c.id).values(title=RENAMED[c.title]))
    if rows:
        op.bulk_insert(titles, rows)


def downgrade() -> None:
    characters = sa.table("characters", sa.column("title", sa.String()))
    bind = op.get_bind()
    for old, new in RENAMED.items():
        bind.execute(sa.update(characters).where(characters.c.title == new).values(title=old))
    op.drop_index("ix_character_titles_character_id", table_name="character_titles")
    op.drop_index("ix_character_titles_user_id", table_name="character_titles")
    op.drop_table("character_titles")
    op.drop_column("characters", "story_waiting")
    op.drop_column("characters", "title_pinned")
