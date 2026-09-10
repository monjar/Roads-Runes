from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class StravaConnection(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "strava_connections"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), unique=True, index=True)
    athlete_id: Mapped[str] = mapped_column(String(40), nullable=False)
    athlete_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    access_token: Mapped[str] = mapped_column(String(255), nullable=False)
    refresh_token: Mapped[str] = mapped_column(String(255), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    scope: Mapped[str | None] = mapped_column(String(120), nullable=True)
