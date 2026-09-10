"""Spatial query helpers.

On PostgreSQL the location-bearing tables carry a generated `geog` geography
column and a GiST index (created by the Alembic migration), and radius queries
use PostGIS `ST_DWithin`. On SQLite (unit/API tests only) we fall back to a
bounding-box prefilter plus a Python haversine check. Production never runs
the fallback.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

from sqlalchemy import Select, and_, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.geo import bbox_for_radius, haversine_m


def dialect_name(session: AsyncSession) -> str:
    bind = session.bind
    return bind.dialect.name if bind is not None else "sqlite"


def bbox_filter(stmt: Select[Any], model: Any, latitude: float, longitude: float, radius_m: float) -> Select[Any]:
    min_lat, min_lon, max_lat, max_lon = bbox_for_radius(latitude, longitude, radius_m)
    return stmt.where(
        and_(
            model.latitude >= min_lat,
            model.latitude <= max_lat,
            model.longitude >= min_lon,
            model.longitude <= max_lon,
        )
    )


def st_dwithin(model: Any, latitude: float, longitude: float, radius_m: float) -> Any:
    return text(
        f"ST_DWithin({model.__tablename__}.geog, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography, :r)"
    ).bindparams(lon=longitude, lat=latitude, r=radius_m)


async def select_within_radius(
    session: AsyncSession,
    stmt: Select[Any],
    model: Any,
    latitude: float,
    longitude: float,
    radius_m: float,
) -> Sequence[Any]:
    """Execute `stmt` (selecting rows of `model`) restricted to a radius around a point."""
    if dialect_name(session) == "postgresql":
        result = await session.execute(stmt.where(st_dwithin(model, latitude, longitude, radius_m)))
        return result.scalars().all()
    rows = (await session.execute(bbox_filter(stmt, model, latitude, longitude, radius_m))).scalars().all()
    return [r for r in rows if haversine_m(latitude, longitude, r.latitude, r.longitude) <= radius_m]
