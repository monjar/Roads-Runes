from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Any

from sqlalchemy import Boolean, Date, Float, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin

AWAKE = "AWAKE"
DORMANT = "DORMANT"
DEFEATED = "DEFEATED"
STATUSES = (AWAKE, DORMANT, DEFEATED)


class OldOne(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A legend (docs/ROADMAP.md 0.8.0, Appendix I): one great creature at a time,
    anchored somewhere the player can reach, fought over several journeys in three
    phases. Written only by app/legends/service.py.

    Healing and sleeping are worked out on read from `last_hit_at` (or `woke_at`),
    never by a clock: `phase_hold_left` is what was left when it was last hit, put to
    sleep, or woken.
    """

    __tablename__ = "old_ones"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    character_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("characters.id", ondelete="CASCADE"), nullable=False)
    # The legend's id in world_objects/config/legends.json ("fog-dragon").
    species_id: Mapped[str] = mapped_column(String(30), nullable=False)
    # "The Fog Dragon", or "The Fog Dragon II" the second time round.
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    anchor_name: Mapped[str | None] = mapped_column(String(160), nullable=True)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default=AWAKE)
    # 1 to 3; the phase being fought (3 once defeated).
    phase: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    phase_hold_max: Mapped[int] = mapped_column(Integer, nullable=False, default=500)
    phase_hold_left: Mapped[int] = mapped_column(Integer, nullable=False, default=500)
    # What each journey did, by ride id: {"phase", "amount", "kinds", "day", ...}. A
    # rerun of the same ride replaces its entry, never adds a second.
    wounds: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    # The one free move has been used.
    moved: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    woke_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    last_hit_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    # At most one phase breaks a day: the day the last one did.
    last_phase_break_day: Mapped[date | None] = mapped_column(Date, nullable=True)
    defeated_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    # {"round", "discoveryId", "sleptAt", "healthScale"}.
    payload: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
