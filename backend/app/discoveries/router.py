from __future__ import annotations

import uuid

from fastapi import APIRouter, Query, status

from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.pagination import Page, clamp_limit
from app.discoveries import service
from app.discoveries.schemas import (
    DiscoveryCreate,
    DiscoveryOut,
    DiscoverySummary,
    UserDiscoveryIn,
    UserDiscoveryOut,
)

router = APIRouter(prefix="/discoveries", tags=["discoveries"])


@router.get("", response_model=Page[DiscoverySummary])
async def nearby(
    user: CurrentUser,
    db: DBDep,
    latitude: float = Query(ge=-90, le=90),
    longitude: float = Query(ge=-180, le=180),
    radiusMeters: float = Query(default=3000, ge=50, le=50000),
    category: str | None = None,
    limit: int | None = None,
) -> Page[DiscoverySummary]:
    rows = await service.nearby(db, latitude, longitude, radiusMeters, category, clamp_limit(limit))
    found = await service.user_found(db, user.id, [r.id for r in rows])
    return Page(items=service.summaries(rows, found), nextCursor=None)


@router.get("/mine", response_model=Page[UserDiscoveryOut])
async def mine(user: CurrentUser, db: DBDep, limit: int | None = None) -> Page[UserDiscoveryOut]:
    return Page(
        items=[service.user_discovery_out(ud) for ud in await service.mine(db, user, clamp_limit(limit))],
        nextCursor=None,
    )


@router.post("", response_model=DiscoveryOut, status_code=status.HTTP_201_CREATED)
async def create(payload: DiscoveryCreate, user: CurrentUser, db: DBDep, settings: SettingsDep) -> DiscoveryOut:
    d = await service.create_custom(db, user, payload, settings.h3_resolution)
    return await service.get(db, user, d.id)


@router.get("/{discovery_id}", response_model=DiscoveryOut)
async def get(discovery_id: uuid.UUID, user: CurrentUser, db: DBDep) -> DiscoveryOut:
    return await service.get(db, user, discovery_id)


@router.put("/{discovery_id}/user", response_model=UserDiscoveryOut)
async def put_user(discovery_id: uuid.UUID, payload: UserDiscoveryIn, user: CurrentUser, db: DBDep) -> UserDiscoveryOut:
    return service.user_discovery_out(await service.upsert_user_discovery(db, user, discovery_id, payload))
