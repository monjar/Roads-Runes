"""Legends (0.8.0): the one awake, those defeated, and the one free move."""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.characters.service import get_character
from app.core.deps import CurrentUser, DBDep, SettingsDep, get_router_client
from app.core.security import utcnow
from app.legends import service
from app.legends.models import DEFEATED, DORMANT
from app.legends.schemas import LegendOut, LegendsOut, LegendSummaryOut

router = APIRouter(prefix="/legends", tags=["legends"])

EngineDep = Annotated[object, Depends(get_router_client)]


@router.get("", response_model=LegendsOut)
async def legends(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    engine: EngineDep,
    latitude: float | None = Query(default=None, ge=-90, le=90),
    longitude: float | None = Query(default=None, ge=-180, le=180),
) -> LegendsOut:
    """The legend awake (waking one first if it is due), those defeated, those
    asleep, and how many creatures until the next wakes. Where the player is
    (optional) places a legend for someone with no journeys counted yet; otherwise
    it lives near where they usually start."""
    character = await get_character(db, user)
    near = (latitude, longitude) if latitude is not None and longitude is not None else None
    await service.maybe_wake(db, settings, engine, character, near=near)  # type: ignore[arg-type]
    now = utcnow()
    rows = await service.legends_of(db, character)
    awake = next((r for r in rows if r.status == "AWAKE"), None)
    return LegendsOut(
        awake=LegendOut(**service.legend_out(awake, now)) if awake else None,
        defeated=[LegendSummaryOut(**service.summary_out(r)) for r in rows if r.status == DEFEATED],
        sleeping=[LegendSummaryOut(**service.summary_out(r)) for r in rows if r.status == DORMANT],
        creaturesUntilNext=await service.creatures_until_next(db, character),
    )


@router.get("/{legend_id}", response_model=LegendOut)
async def legend(legend_id: uuid.UUID, user: CurrentUser, db: DBDep) -> LegendOut:
    """One legend, with each journey that hurt it. 404 NO_SUCH_LEGEND."""
    character = await get_character(db, user)
    row = await service.get_legend(db, character, legend_id)
    service.settle_sleep(row, utcnow())
    await db.flush()
    return LegendOut(**service.legend_out(row, utcnow(), journeys=True))


@router.post("/{legend_id}/move", response_model=LegendOut)
async def move(
    legend_id: uuid.UUID, user: CurrentUser, db: DBDep, settings: SettingsDep, engine: EngineDep
) -> LegendOut:
    """The one free move: somewhere else it may live, that you can reach. 409
    ALREADY_MOVED, NOT_AWAKE, NOWHERE_ELSE; 404 NO_SUCH_LEGEND."""
    character = await get_character(db, user)
    row = await service.move(db, settings, engine, character, legend_id)  # type: ignore[arg-type]
    return LegendOut(**service.legend_out(row, utcnow(), journeys=True))
