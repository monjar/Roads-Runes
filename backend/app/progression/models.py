from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, UUIDPrimaryKeyMixin


class XPEvent(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Immutable ledger of every XP grant. XP is never edited directly."""

    __tablename__ = "xp_events"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    character_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("characters.id", ondelete="CASCADE"), index=True)
    event_type: Mapped[str] = mapped_column(String(40), nullable=False)
    xp: Mapped[int] = mapped_column(Integer, nullable=False)
    class_xp: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rides.id", ondelete="SET NULL"), nullable=True, index=True
    )
    quest_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("quest_instances.id", ondelete="SET NULL"), nullable=True
    )
    payload: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)


class RewardEvent(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Non-XP rewards: level-ups, ability unlocks, titles, items."""

    __tablename__ = "reward_events"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    character_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("characters.id", ondelete="CASCADE"), index=True)
    reward_type: Mapped[str] = mapped_column(String(40), nullable=False)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rides.id", ondelete="SET NULL"), nullable=True, index=True
    )
    payload: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
