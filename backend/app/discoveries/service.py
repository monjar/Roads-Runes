from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound
from app.core.security import utcnow
from app.db.spatial import select_within_radius
from app.discoveries.models import Discovery, UserDiscovery
from app.discoveries.schemas import (
    DiscoveryCreate,
    DiscoveryOut,
    DiscoverySummary,
    UserDiscoveryIn,
    UserDiscoveryOut,
)
from app.exploration.cells import cell_for
from app.users.models import User

DISCOVERY_RADIUS_M = 60.0


async def nearby(
    db: AsyncSession,
    latitude: float,
    longitude: float,
    radius_m: float,
    category: str | None = None,
    limit: int = 200,
) -> list[Discovery]:
    stmt = select(Discovery).where(Discovery.moderation_status == "APPROVED", Discovery.cycling_accessible.is_(True))
    if category:
        stmt = stmt.where(Discovery.category == category)
    # Nearest first: capping an unordered query hands back an arbitrary slice of a city.
    rows = await select_within_radius(
        db, stmt, Discovery, latitude, longitude, radius_m, limit=limit, nearest_first=True
    )
    return list(rows)


async def user_found(
    db: AsyncSession, user_id: uuid.UUID, discovery_ids: list[uuid.UUID]
) -> dict[uuid.UUID, UserDiscovery]:
    if not discovery_ids:
        return {}
    rows = (
        (
            await db.execute(
                select(UserDiscovery).where(
                    UserDiscovery.user_id == user_id, UserDiscovery.discovery_id.in_(discovery_ids)
                )
            )
        )
        .scalars()
        .all()
    )
    return {r.discovery_id: r for r in rows}


def summaries(discoveries: list[Discovery], found: dict[uuid.UUID, UserDiscovery]) -> list[DiscoverySummary]:
    out = []
    for d in discoveries:
        ud = found.get(d.id)
        out.append(
            DiscoverySummary(
                id=d.id,
                name=d.name,
                category=d.category,
                latitude=d.latitude,
                longitude=d.longitude,
                source=d.source,
                discoveredByUser=ud is not None,
                discoveredAt=ud.discovered_at if ud else None,
            )
        )
    return out


def user_discovery_out(ud: UserDiscovery) -> UserDiscoveryOut:
    return UserDiscoveryOut(
        discoveryId=ud.discovery_id,
        discoveredAt=ud.discovered_at,
        rideId=ud.ride_id,
        note=ud.note,
        rating=ud.rating,
        tags=list(ud.tags or []),
        photoIds=list(ud.photo_ids or []),
        visibility=ud.visibility,
    )


async def get(db: AsyncSession, user: User, discovery_id: uuid.UUID) -> DiscoveryOut:
    d = await db.get(Discovery, discovery_id)
    if d is None or (d.moderation_status != "APPROVED" and d.created_by_user_id != user.id):
        raise NotFound("Discovery not found")
    ud = (await user_found(db, user.id, [d.id])).get(d.id)
    return DiscoveryOut(
        id=d.id,
        name=d.name,
        category=d.category,
        latitude=d.latitude,
        longitude=d.longitude,
        source=d.source,
        discoveredByUser=ud is not None,
        discoveredAt=ud.discovered_at if ud else None,
        description=d.description,
        osmId=d.osm_id,
        tags=d.tags or {},
        userDiscovery=user_discovery_out(ud) if ud else None,
    )


async def mark_found(
    db: AsyncSession,
    user_id: uuid.UUID,
    discovery: Discovery,
    ride_id: uuid.UUID | None,
    at: datetime,
) -> UserDiscovery | None:
    existing = (await user_found(db, user_id, [discovery.id])).get(discovery.id)
    if existing:
        return None
    ud = UserDiscovery(user_id=user_id, discovery_id=discovery.id, ride_id=ride_id, discovered_at=at)
    db.add(ud)
    await db.flush()
    return ud


async def discoveries_along(
    db: AsyncSession,
    user_id: uuid.UUID,
    points: list[tuple[float, float]],
    ride_id: uuid.UUID,
    at: datetime,
    stride: int = 5,
) -> list[Discovery]:
    """Discoveries the rider passed within DISCOVERY_RADIUS_M of, not previously found."""
    if not points:
        return []
    lats = [p[0] for p in points]
    lons = [p[1] for p in points]
    centre_lat, centre_lon = (max(lats) + min(lats)) / 2, (max(lons) + min(lons)) / 2
    from app.core.geo import haversine_m

    radius = (
        max(
            haversine_m(centre_lat, centre_lon, max(lats), max(lons)),
            haversine_m(centre_lat, centre_lon, min(lats), min(lons)),
        )
        + DISCOVERY_RADIUS_M
    )
    candidates = await nearby(db, centre_lat, centre_lon, min(radius, 60000), limit=2000)
    if not candidates:
        return []
    found = await user_found(db, user_id, [c.id for c in candidates])
    hits: list[Discovery] = []
    sampled = points[::stride] if len(points) > stride else points
    for c in candidates:
        if c.id in found:
            continue
        for lat, lon in sampled:
            if haversine_m(lat, lon, c.latitude, c.longitude) <= DISCOVERY_RADIUS_M:
                hits.append(c)
                break
    for c in hits:
        await mark_found(db, user_id, c, ride_id, at)
    return hits


async def upsert_user_discovery(
    db: AsyncSession, user: User, discovery_id: uuid.UUID, payload: UserDiscoveryIn
) -> UserDiscovery:
    d = await db.get(Discovery, discovery_id)
    if d is None:
        raise NotFound("Discovery not found")
    ud = (await user_found(db, user.id, [d.id])).get(d.id)
    if ud is None:
        ud = UserDiscovery(user_id=user.id, discovery_id=d.id, discovered_at=utcnow())
        db.add(ud)
    if payload.note is not None:
        ud.note = payload.note
    if payload.rating is not None:
        ud.rating = payload.rating
    ud.tags = payload.tags
    ud.photo_ids = payload.photoIds
    if payload.visibility is not None:
        # User-generated content stays private until moderation exists (spec §24).
        ud.visibility = "PRIVATE" if payload.visibility == "PUBLIC" else payload.visibility
    await db.flush()
    return ud


async def create_custom(db: AsyncSession, user: User, payload: DiscoveryCreate, resolution: int) -> Discovery:
    d = Discovery(
        name=payload.name.strip(),
        category=payload.category,
        description=payload.description,
        latitude=payload.latitude,
        longitude=payload.longitude,
        source="USER",
        created_by_user_id=user.id,
        moderation_status="PENDING",
        h3_index=cell_for(payload.latitude, payload.longitude, resolution),
    )
    db.add(d)
    await db.flush()
    await mark_found(db, user.id, d, None, utcnow())
    return d


async def mine(db: AsyncSession, user: User, limit: int) -> list[UserDiscovery]:
    return list(
        (
            await db.execute(
                select(UserDiscovery)
                .where(UserDiscovery.user_id == user.id)
                .order_by(UserDiscovery.discovered_at.desc())
                .limit(limit)
            )
        ).scalars()
    )
