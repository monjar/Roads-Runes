from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Boolean, Float, ForeignKey, Index, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin

# 0.8.0: a LAIR (seven tiles round a park, world_objects/lairs.py), and buried
# treasure: a CHEST that is HIDDEN until a journey passes it (inventory/treasure.py).
# A hidden thing is never shown: every query for the map asks for SPAWNED.
KINDS = ("CHEST", "COLLECTABLE", "MONSTER", "LAIR")
HIDDEN = "HIDDEN"
STATUSES = ("SPAWNED", "CLAIMED", "EXPIRED", HIDDEN)


class WorldObject(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Something placed in one player's world: a chest to pass, a piece to collect, a monster to beat.

    Anchored to a real place (a Discovery) so it is somewhere a person can actually
    get to, and owned by one user: two players never fight over the same troll.
    """

    __tablename__ = "world_objects"
    __table_args__ = (
        UniqueConstraint("user_id", "seed", name="uq_world_objects_user_seed"),
        Index("ix_world_objects_user_status_expires", "user_id", "status", "expires_at"),
        Index("ix_world_objects_user_lat_lon", "user_id", "latitude", "longitude"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(12), nullable=False)
    status: Mapped[str] = mapped_column(String(10), nullable=False, default="SPAWNED")
    tier: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    anchor_discovery_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("discoveries.id", ondelete="SET NULL"), nullable=True
    )
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    h3_index: Mapped[str | None] = mapped_column(String(16), nullable=True)
    seed: Mapped[str] = mapped_column(String(96), nullable=False)
    bounty: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    reward_ac: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # {name, flavour, anchorName, killMethods: [{method, params, hint}], setId, piece}
    payload: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    spawned_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    claimed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    claimed_ride_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("rides.id", ondelete="SET NULL"), nullable=True
    )
    claim_payload: Mapped[dict[str, Any] | None] = mapped_column(JSONType, nullable=True)
