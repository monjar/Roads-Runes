from __future__ import annotations

from sqlalchemy import String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, UUIDPrimaryKeyMixin


class FeatureFlagOverride(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A flag switched on /admin, over what the code and FEATURE_FLAGS say. No row means
    no override; clearing one deletes it."""

    __tablename__ = "feature_flag_overrides"

    name: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    enabled: Mapped[bool] = mapped_column(nullable=False)
    note: Mapped[str | None] = mapped_column(String(200), nullable=True)
