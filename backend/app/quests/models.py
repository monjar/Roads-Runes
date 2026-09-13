from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Float, ForeignKey, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class QuestInstance(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A quest generated for (and owned by) one user."""

    __tablename__ = "quest_instances"
    __table_args__ = (Index("ix_quest_instances_user_status", "user_id", "status"),)

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    template_id: Mapped[str] = mapped_column(String(64), nullable=False)
    quest_type: Mapped[str] = mapped_column(String(40), nullable=False)
    character_class: Mapped[str] = mapped_column(String(20), nullable=False)
    # How the quest is meant to be done: RIDE | RUN | WALK (core/activity.py).
    activity: Mapped[str] = mapped_column(String(8), nullable=False, default="RIDE", server_default="RIDE")
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str] = mapped_column(String(2000), nullable=False)
    narrative: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    difficulty: Mapped[str] = mapped_column(String(12), nullable=False)
    recommended_distance_km: Mapped[float] = mapped_column(Float, nullable=False)
    estimated_duration_minutes: Mapped[int] = mapped_column(Integer, nullable=False)
    base_xp: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(String(12), nullable=False, default="AVAILABLE")
    expires_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    story_quest_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("story_quests.id", ondelete="SET NULL"), nullable=True
    )
    party_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("parties.id", ondelete="SET NULL"), nullable=True)
    # Origin: where the quest was generated from (centre of the search).
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    rewards: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    suggested_route_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("routes.id", ondelete="SET NULL"), nullable=True
    )
    ride_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("rides.id", ondelete="SET NULL"), nullable=True)
    generation_seed: Mapped[str | None] = mapped_column(String(64), nullable=True)
    accepted_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    started_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)

    objectives: Mapped[list[QuestObjective]] = relationship(
        back_populates="quest",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="QuestObjective.order",
    )


class QuestObjective(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "quest_objectives"

    quest_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("quest_instances.id", ondelete="CASCADE"), index=True)
    objective_type: Mapped[str] = mapped_column(String(40), nullable=False)
    title: Mapped[str] = mapped_column(String(160), nullable=False)
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    radius_meters: Mapped[float | None] = mapped_column(Float, nullable=True)
    target_meters: Mapped[float | None] = mapped_column(Float, nullable=True)
    target_cells: Mapped[list[Any] | None] = mapped_column(JSONType, nullable=True)
    target_elevation_meters: Mapped[float | None] = mapped_column(Float, nullable=True)
    target_count: Mapped[int | None] = mapped_column(Integer, nullable=True)
    discovery_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("discoveries.id", ondelete="SET NULL"), nullable=True
    )
    required: Mapped[bool] = mapped_column(default=True, nullable=False)
    order: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    completion_rule: Mapped[str] = mapped_column(String(12), nullable=False, default="INDIVIDUAL")
    status: Mapped[str] = mapped_column(String(12), nullable=False, default="PENDING")
    progress_current: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    progress_target: Mapped[float] = mapped_column(Float, default=1.0, nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    provisional: Mapped[bool] = mapped_column(default=False, nullable=False)
    extra: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)

    quest: Mapped[QuestInstance] = relationship(back_populates="objectives")


class QuestProgressEvent(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Client-reported objective events, kept for validation and auditing."""

    __tablename__ = "quest_progress"

    quest_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("quest_instances.id", ondelete="CASCADE"), index=True)
    objective_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("quest_objectives.id", ondelete="CASCADE"), index=True)
    occurred_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    value: Mapped[float | None] = mapped_column(Float, nullable=True)
    source: Mapped[str] = mapped_column(String(12), nullable=False, default="CLIENT")
    validated: Mapped[bool | None] = mapped_column(nullable=True)


class StoryArc(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "story_arcs"

    slug: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str] = mapped_column(String(2000), nullable=False)
    character_class: Mapped[str | None] = mapped_column(String(20), nullable=True)
    min_level: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    region_h3: Mapped[str | None] = mapped_column(String(16), nullable=True)
    enabled: Mapped[bool] = mapped_column(default=True, nullable=False)

    quests: Mapped[list[StoryQuest]] = relationship(
        back_populates="arc",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="StoryQuest.sequence",
    )


class StoryQuest(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "story_quests"

    arc_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("story_arcs.id", ondelete="CASCADE"), index=True)
    slug: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    sequence: Mapped[int] = mapped_column(Integer, nullable=False)
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    description: Mapped[str] = mapped_column(String(2000), nullable=False)
    template_id: Mapped[str] = mapped_column(String(64), nullable=False)
    prerequisite_slug: Mapped[str | None] = mapped_column(String(64), nullable=True)
    definition: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)

    arc: Mapped[StoryArc] = relationship(back_populates="quests")
