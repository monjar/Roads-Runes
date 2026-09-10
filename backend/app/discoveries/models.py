from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Float, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class Discovery(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A discoverable place (POI). Sourced from OSM, curation or users."""

    __tablename__ = "discoveries"
    __table_args__ = (Index("ix_discoveries_lat_lon", "latitude", "longitude"),)

    name: Mapped[str] = mapped_column(String(160), nullable=False)
    category: Mapped[str] = mapped_column(String(20), nullable=False, index=True)
    description: Mapped[str | None] = mapped_column(String(2000), nullable=True)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    source: Mapped[str] = mapped_column(String(12), nullable=False, default="OSM")
    osm_id: Mapped[str | None] = mapped_column(String(40), nullable=True, unique=True)
    h3_index: Mapped[str | None] = mapped_column(String(16), nullable=True, index=True)
    tags: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), nullable=True
    )
    moderation_status: Mapped[str] = mapped_column(String(12), nullable=False, default="APPROVED")
    cycling_accessible: Mapped[bool] = mapped_column(default=True, nullable=False)
    discovery_xp: Mapped[int | None] = mapped_column(Integer, nullable=True)


class UserDiscovery(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "user_discoveries"
    __table_args__ = (UniqueConstraint("user_id", "discovery_id"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    discovery_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("discoveries.id", ondelete="CASCADE"), index=True)
    ride_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("rides.id", ondelete="SET NULL"), nullable=True)
    discovered_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    note: Mapped[str | None] = mapped_column(String(4000), nullable=True)
    rating: Mapped[int | None] = mapped_column(Integer, nullable=True)
    tags: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    photo_ids: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    visibility: Mapped[str] = mapped_column(String(10), nullable=False, default="PRIVATE")
