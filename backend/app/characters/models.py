from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Float, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class Character(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "characters"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), unique=True, index=True)
    name: Mapped[str] = mapped_column(String(40), nullable=False)
    character_class: Mapped[str] = mapped_column(String(20), nullable=False)  # class id (EXPLORER…)
    overall_xp: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    class_xp: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    overall_level: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    class_level: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    ability_points: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    title: Mapped[str | None] = mapped_column(String(60), nullable=True)
    # Class XP and level of the classes this character has been, keyed by class id,
    # so switching back restores them: {"WIZARD": {"classXp": 1200, "classLevel": 4}}.
    class_progress: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    class_changes: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    class_changed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    abilities: Mapped[list[CharacterAbility]] = relationship(
        back_populates="character", cascade="all, delete-orphan", lazy="selectin"
    )


class CharacterAbility(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "character_abilities"
    __table_args__ = (UniqueConstraint("character_id", "ability_id"),)

    character_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("characters.id", ondelete="CASCADE"), index=True)
    ability_id: Mapped[str] = mapped_column(String(64), nullable=False)
    rank: Mapped[int] = mapped_column(Integer, default=1, nullable=False)

    character: Mapped[Character] = relationship(back_populates="abilities")


class Bike(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "bikes"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    bike_type: Mapped[str] = mapped_column(String(20), nullable=False)
    allow_gravel: Mapped[bool] = mapped_column(default=True, nullable=False)
    allow_trails: Mapped[bool] = mapped_column(default=False, nullable=False)
    max_technical_surface: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    is_default: Mapped[bool] = mapped_column(default=False, nullable=False)
    archived: Mapped[bool] = mapped_column(default=False, nullable=False)


class RiderProfile(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Cycling difficulty profile. NOT the RPG character (spec §30)."""

    __tablename__ = "rider_profiles"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), unique=True, index=True)
    comfortable_distance_km: Mapped[float] = mapped_column(Float, default=25.0, nullable=False)
    comfortable_elevation_gain: Mapped[float] = mapped_column(Float, default=300.0, nullable=False)
    max_preferred_gradient: Mapped[float] = mapped_column(Float, default=8.0, nullable=False)
    traffic_tolerance: Mapped[float] = mapped_column(Float, default=0.3, nullable=False)
    gravel_comfort: Mapped[float] = mapped_column(Float, default=0.5, nullable=False)
    technical_trail_comfort: Mapped[float] = mapped_column(Float, default=0.2, nullable=False)
    cycleway_preference: Mapped[float] = mapped_column(Float, default=0.8, nullable=False)
    # How this player usually moves, and how far is comfortable on foot.
    default_activity: Mapped[str] = mapped_column(String(8), default="RIDE", server_default="RIDE", nullable=False)
    run_distance_km: Mapped[float] = mapped_column(Float, default=8.0, server_default="8", nullable=False)
    walk_distance_km: Mapped[float] = mapped_column(Float, default=5.0, server_default="5", nullable=False)
