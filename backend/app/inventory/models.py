from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Boolean, Float, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class RuneHolding(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A rune the character holds: rank I from its first stone, raised with stones
    and coins (inventory/service.py, the only writer)."""

    __tablename__ = "rune_holdings"
    __table_args__ = (UniqueConstraint("character_id", "rune_id"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    character_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("characters.id", ondelete="CASCADE"), index=True)
    rune_id: Mapped[str] = mapped_column(String(20), nullable=False)
    rank: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    # Stones found since it was held, towards the next rank.
    shards: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    first_found_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)


class Loadout(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """What the character carries into an outing: the runes inscribed (0.7.0), the
    gear worn and the consumables in the bag (0.7.2)."""

    __tablename__ = "loadouts"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    character_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("characters.id", ondelete="CASCADE"), unique=True, index=True
    )
    inscriptions: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    # Stones of runes already held, in a row: after enough, the next is one not held.
    repeats: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    # 0.7.2: what is worn, by slot ({"BELL": "<inventory item uuid>"}), and the
    # consumables held, by id ({"LAMP": 2}).
    gear: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    consumables: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    # Creatures defeated and chests opened since the last Rare-or-better item: the pity count.
    finishes_since_rare: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    # 0.9.0: the look worn ({"ink": "ink:sage", "markerFrame": "marker:rope", "crestFrame":
    # "crest:legs-2"}); a missing key is the default (inventory/cosmetics.py).
    look: Mapped[dict[str, Any] | None] = mapped_column(JSONType, nullable=True)


class RuneCut(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A rune cut with a track: where, which, and whether it woke an inscribed rune.
    Drawn on the maps; counted by the Hand deed."""

    __tablename__ = "rune_cuts"
    __table_args__ = (UniqueConstraint("ride_id", "rune_id", "source"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rides.id", ondelete="CASCADE"), nullable=True, index=True
    )
    rune_id: Mapped[str] = mapped_column(String(20), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    woke: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # WAKING (anywhere on the outing), FIGHT (at a creature) or QUEST (an INSCRIBE_RUNE objective).
    source: Mapped[str] = mapped_column(String(12), nullable=False)
    place_name: Mapped[str | None] = mapped_column(String(160), nullable=True)
    cut_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)


class ItemEvent(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """The inventory ledger: every stone, rank and inscription, once. A rerun of the
    same ride and object writes nothing new (`key` is unique)."""

    __tablename__ = "item_events"
    __table_args__ = (UniqueConstraint("user_id", "key"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(20), nullable=False)
    key: Mapped[str] = mapped_column(String(160), nullable=False)
    rune_id: Mapped[str | None] = mapped_column(String(20), nullable=True)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("rides.id", ondelete="SET NULL"), nullable=True)
    payload: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)


class CharacterDeed(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A deed's lifetime count and the highest threshold reached, or a record (the
    furthest from home, the most new ground at once, the highest point)."""

    __tablename__ = "character_deeds"
    __table_args__ = (UniqueConstraint("character_id", "deed_id"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    character_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("characters.id", ondelete="CASCADE"), index=True)
    deed_id: Mapped[str] = mapped_column(String(30), nullable=False)
    value: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    tier: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("rides.id", ondelete="SET NULL"), nullable=True)


class InventoryItem(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A piece of gear the character has had (0.7.2): worn, in the bag, or sold.
    Never deleted, so "one of each Legendary, ever" can be read from it. Written
    only by inventory/service.py; `source_key` is the ledger key it came by."""

    __tablename__ = "inventory_items"
    __table_args__ = (UniqueConstraint("user_id", "source_key"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    character_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("characters.id", ondelete="CASCADE"), index=True)
    item_id: Mapped[str] = mapped_column(String(40), nullable=False)
    rarity: Mapped[str] = mapped_column(String(12), nullable=False)
    # MONSTER, BOUNTY, CHEST, QUEST, STALL, SEALED_CHEST.
    source: Mapped[str] = mapped_column(String(20), nullable=False)
    source_key: Mapped[str] = mapped_column(String(160), nullable=False)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("rides.id", ondelete="SET NULL"), nullable=True)
    acquired_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    sold_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    sold_for: Mapped[int | None] = mapped_column(Integer, nullable=True)
