"""Districts (docs/ROADMAP.md 0.9.0, Appendix J): real named areas from OpenStreetMap
place nodes, and how far each player has explored them."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Float, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin

KINDS = ("suburb", "neighbourhood", "quarter", "village", "town", "hamlet")


class Region(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A district: one OpenStreetMap place node with a name. Its tiles are worked out,
    never stored: a cell belongs to the nearest place node within 4 km
    (districts/geo.py). Written by the tile import and the ways job only."""

    __tablename__ = "regions"

    osm_id: Mapped[str] = mapped_column(String(32), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    kind: Mapped[str] = mapped_column(String(20), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    # The importer's tile, without its version ("514:-1"), for the 3×3 lookup.
    tile: Mapped[str] = mapped_column(String(32), nullable=False, index=True)
    # Its tiles with a road or path in them (the honest %), once fetched; null until then.
    way_cells: Mapped[list[Any] | None] = mapped_column(JSONType, nullable=True)
    way_cells_fetched_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    # "the Riverlands", from its places (districts/titles.py).
    epithet: Mapped[str | None] = mapped_column(String(40), nullable=True)
    place_counts: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)


class UserRegion(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """How far one player has explored one district. Cells never regress, so neither
    do these counts; "yours" is worked out from them and the last pass."""

    __tablename__ = "user_regions"
    __table_args__ = (UniqueConstraint("user_id", "region_id"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    region_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("regions.id", ondelete="CASCADE"), index=True)
    explored_cells: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    way_cells_explored: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    first_passed_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    last_passed_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    # When it last became yours; kept after it lapses ("was yours").
    yours_since: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    # The ISO week its pay was last counted in ("2026-W41").
    last_paid_week: Mapped[str | None] = mapped_column(String(10), nullable=True)
