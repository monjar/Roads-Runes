"""Districts (0.9.0): the ones passed through, one with its ledger, and the one at a
point (the Watch names it at a standstill)."""

from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, Query

from app.characters.service import maybe_character
from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.errors import NotFound
from app.core.security import utcnow
from app.districts import service
from app.districts.models import Region
from app.districts.schemas import DistrictDetailOut, DistrictLedgerOut, DistrictOut

router = APIRouter(prefix="/districts", tags=["districts"])


async def _rules(db: Any, user: Any) -> dict[str, float]:
    """The runes and gear acting now (Fehu, Othala)."""
    from app.inventory.service import sheet_for

    character = await maybe_character(db, user.id)
    return dict((await sheet_for(db, character)).rules) if character is not None else {}


@router.get("", response_model=list[DistrictOut])
async def districts(user: CurrentUser, db: DBDep) -> list[DistrictOut]:
    """Every district passed through, last passed first."""
    rules = await _rules(db, user)
    now = utcnow()
    return [
        DistrictOut(**service.district_out(region, row, now, rules))
        for region, row in await service.passed(db, user.id)
    ]


@router.get("/here", response_model=DistrictOut | None)
async def here(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    lat: float = Query(ge=-90, le=90),
    lon: float = Query(ge=-180, le=180),
) -> DistrictOut | None:
    """The district at a point, or null where there is none (or none is known yet)."""
    region = await service.here(db, lat, lon, settings.h3_resolution)
    if region is None:
        return None
    row = await service.row_for(db, user.id, region.id)
    return DistrictOut(**service.district_out(region, row, utcnow(), await _rules(db, user)))


@router.get("/{district_id}", response_model=DistrictDetailOut)
async def district(district_id: uuid.UUID, user: CurrentUser, db: DBDep, settings: SettingsDep) -> DistrictDetailOut:
    """One district, with its ledger: places found, creatures defeated, runes cut and
    quests done within its tiles, and when it was first and last passed."""
    region = await db.get(Region, district_id)
    if region is None:
        raise NotFound("We couldn't find that district. Go back to your districts and try again.")
    row = await service.row_for(db, user.id, region.id)
    out = service.district_out(region, row, utcnow(), await _rules(db, user))
    ledger = await service.ledger(db, user.id, region, row, settings.h3_resolution)
    return DistrictDetailOut(**out, ledger=DistrictLedgerOut(**ledger))
