from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import Float, ForeignKey, Integer, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, JSONType, TimestampMixin, UUIDPrimaryKeyMixin


class Route(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """A generated route alternative. Geometry stored as JSON coordinate list
    plus encoded polyline; on PostgreSQL a `geom` linestring column is also
    populated by the migration-defined trigger for corridor searches."""

    __tablename__ = "routes"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    quest_id: Mapped[uuid.UUID | None] = mapped_column(Uuid, nullable=True, index=True)
    bike_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("bikes.id", ondelete="SET NULL"), nullable=True)
    label: Mapped[str] = mapped_column(String(20), nullable=False)
    profile: Mapped[str] = mapped_column(String(20), nullable=False)
    activity: Mapped[str] = mapped_column(String(8), nullable=False, default="RIDE", server_default="RIDE")
    engine: Mapped[str] = mapped_column(String(20), nullable=False, default="graphhopper")
    distance_meters: Mapped[float] = mapped_column(Float, nullable=False)
    estimated_duration_seconds: Mapped[int] = mapped_column(Integer, nullable=False)
    elevation_gain_meters: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    elevation_loss_meters: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    highest_point_meters: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    max_gradient_percent: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    average_climb_gradient_percent: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    longest_climb: Mapped[dict[str, Any] | None] = mapped_column(JSONType, nullable=True)
    surface: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    cycleway_fraction: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    traffic_exposure: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    new_territory_fraction: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    quest_objective_coverage: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    score: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    coordinates: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)  # [[lon, lat, ele?]]
    encoded_polyline: Mapped[str] = mapped_column(String, nullable=False, default="")
    instructions: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    elevation_samples: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    climbs: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    pois: Mapped[list[Any]] = mapped_column(JSONType, default=list, nullable=False)
    request: Mapped[dict[str, Any]] = mapped_column(JSONType, default=dict, nullable=False)
    min_lat: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    min_lon: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    max_lat: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    max_lon: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
