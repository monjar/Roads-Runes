from __future__ import annotations

import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import Float, ForeignKey, Index, Integer, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, TZDateTime, UUIDPrimaryKeyMixin


class Ride(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "rides"
    __table_args__ = (
        UniqueConstraint("user_id", "client_ride_id"),
        Index("ix_rides_user_started", "user_id", "started_at"),
    )

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    client_ride_id: Mapped[uuid.UUID] = mapped_column(nullable=False)
    status: Mapped[str] = mapped_column(String(12), nullable=False, default="RECORDING")
    # RIDE | RUN | WALK (core/activity.py). The table keeps its name; a run is a "ride" here.
    activity: Mapped[str] = mapped_column(String(8), nullable=False, default="RIDE", server_default="RIDE")
    title: Mapped[str | None] = mapped_column(String(120), nullable=True)
    notes: Mapped[str | None] = mapped_column(String(4000), nullable=True)
    started_at: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    distance_meters: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    duration_seconds: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    moving_seconds: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    elevation_gain_meters: Mapped[float] = mapped_column(Float, default=0.0, nullable=False)
    active_calories: Mapped[float | None] = mapped_column(Float, nullable=True)
    average_speed_mps: Mapped[float | None] = mapped_column(Float, nullable=True)
    max_speed_mps: Mapped[float | None] = mapped_column(Float, nullable=True)
    quest_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True, index=True)
    bike_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("bikes.id", ondelete="SET NULL"), nullable=True)
    route_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("routes.id", ondelete="SET NULL"), nullable=True)
    visibility: Mapped[str] = mapped_column(String(10), nullable=False, default="PRIVATE")
    healthkit_workout_id: Mapped[str | None] = mapped_column(String(80), nullable=True)
    point_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    # Client-reported exploration candidates, merged with server-derived cells at processing.
    client_cells: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    objective_events: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    # What the phone thinks it beat or opened on the way (world_objects); the server decides.
    encounter_events: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    processing_result: Mapped[dict[str, Any] | None] = mapped_column(JSONType, nullable=True)
    flags: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    processed_at: Mapped[datetime | None] = mapped_column(TZDateTime, nullable=True)
    strava_activity_id: Mapped[str | None] = mapped_column(String(40), nullable=True)


class RidePoint(UUIDPrimaryKeyMixin, Base):
    __tablename__ = "ride_points"
    __table_args__ = (Index("ix_ride_points_ride_seq", "ride_id", "sequence"),)

    ride_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("rides.id", ondelete="CASCADE"), index=True)
    sequence: Mapped[int] = mapped_column(Integer, nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    timestamp: Mapped[datetime] = mapped_column(TZDateTime, nullable=False)
    altitude_meters: Mapped[float | None] = mapped_column(Float, nullable=True)
    horizontal_accuracy_meters: Mapped[float | None] = mapped_column(Float, nullable=True)
    speed_mps: Mapped[float | None] = mapped_column(Float, nullable=True)
    heart_rate_bpm: Mapped[int | None] = mapped_column(Integer, nullable=True)


class RideRoute(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Simplified ride geometry stored separately from the ride row (spec §37)."""

    __tablename__ = "ride_routes"

    ride_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("rides.id", ondelete="CASCADE"), unique=True, index=True)
    coordinates: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    encoded_polyline: Mapped[str] = mapped_column(String, nullable=False, default="")
    min_lat: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    min_lon: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    max_lat: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    max_lon: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
