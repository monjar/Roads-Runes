from __future__ import annotations

import uuid
from datetime import date, datetime

from sqlalchemy import Date, Float, ForeignKey, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin

PLEDGE_KINDS = ("CREATURE", "QUEST")
PLEDGE_STATUSES = ("PLEDGED", "KEPT", "MISSED")


class Pledge(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A promise to go out for one creature or quest on one day (the player's own
    local date, as the phone sends it). Kept by a journey that day; missed is never
    shown and costs nothing. One a day: a second for the same day replaces it."""

    __tablename__ = "pledges"
    __table_args__ = (UniqueConstraint("user_id", "day", name="uq_pledges_user_id_day"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    day: Mapped[date] = mapped_column(Date, nullable=False)
    # CREATURE (a world object) or QUEST (a quest instance).
    target_kind: Mapped[str] = mapped_column(String(12), nullable=False)
    target_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    # Kept as it was named when pledged: the thing itself may be gone by the evening.
    target_name: Mapped[str] = mapped_column(String(160), nullable=False)
    # "HH:MM", the phone's one local reminder; the server only keeps it.
    remind_at: Mapped[str | None] = mapped_column(String(5), nullable=True)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="PLEDGED")
    kept_ride_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("rides.id", ondelete="SET NULL"), nullable=True)


class Letter(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A line left at a place for the player to find again, a season or more later.
    Never sent anywhere: only its writer reads it."""

    __tablename__ = "letters"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    text: Mapped[str] = mapped_column(String(140), nullable=False)
    # The nearest named place within 80 m when it was written, if any.
    place_name: Mapped[str | None] = mapped_column(String(160), nullable=True)
    written_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    shown_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    shown_ride_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("rides.id", ondelete="SET NULL"), nullable=True)
