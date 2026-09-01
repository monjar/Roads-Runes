from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin

DEFAULT_SETTINGS: dict[str, Any] = {
    "defaultRideVisibility": "PRIVATE",
    "batteryMode": "BALANCED",
    "mapStyle": "ADVENTURE",
    "stravaUploadMode": "NEVER",
    "units": "METRIC",
}


class User(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "users"
    __table_args__ = (UniqueConstraint("apple_subject", name="uq_users_apple_subject"),)

    # Immutable identity: internal UUID + Apple subject (never email).
    apple_subject: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    email: Mapped[str | None] = mapped_column(String(320), nullable=True)
    display_name: Mapped[str] = mapped_column(String(80), nullable=False)
    avatar_url: Mapped[str | None] = mapped_column(String(1024), nullable=True)
    settings: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    is_admin: Mapped[bool] = mapped_column(default=False, nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    def effective_settings(self) -> dict[str, Any]:
        merged = dict(DEFAULT_SETTINGS)
        merged.update(self.settings or {})
        return merged

    @property
    def uuid(self) -> uuid.UUID:
        return self.id
