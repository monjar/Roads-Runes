from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Float, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class UserExplorationCell(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Per-user state of one H3 cell. Rows exist only for non-UNSEEN cells."""

    __tablename__ = "user_exploration_cells"
    __table_args__ = (
        UniqueConstraint("user_id", "h3_index"),
        Index("ix_user_exploration_cells_user_state", "user_id", "state"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    h3_index: Mapped[str] = mapped_column(String(16), nullable=False, index=True)
    resolution: Mapped[int] = mapped_column(Integer, nullable=False)
    state: Mapped[str] = mapped_column(String(12), nullable=False)  # DISCOVERED/VISITED/EXPLORED
    # Cell centre, denormalised for bbox queries and map rendering.
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    distance_inside_m: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    visit_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    first_visited_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    last_visited_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    discovered_via: Mapped[str | None] = mapped_column(String(40), nullable=True)
