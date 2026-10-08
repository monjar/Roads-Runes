from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.pagination import Page, clamp_limit
from app.core.schemas import APIModel
from app.exploration.schemas import ExplorationStats
from app.exploration.service import stats as exploration_stats
from app.quests.models import QuestInstance
from app.quests.service import quest_out
from app.rides import service
from app.rides.models import Ride
from app.rides.schemas import RideOut

router = APIRouter(prefix="/journal", tags=["journal"])


class AdventureEntry(APIModel):
    ride: RideOut
    quest: Any | None
    xpAwarded: int
    discoveries: list[dict[str, Any]]
    newTerritoryMeters: float
    newCells: int
    levelUps: list[dict[str, Any]]
    notes: str | None
    photos: list[str] = []
    # The entry the outing left (0.6.2): a few written lines, composed from its facts.
    entry: str | None = None
    # 0.7.2: the model-written entry, when there is one ({"lines": [...], "by": "model"}).
    entryWritten: dict[str, Any] | None = None


async def entry(db: AsyncSession, ride: Ride) -> AdventureEntry:
    result = ride.processing_result or {}
    quest = await db.get(QuestInstance, ride.quest_id) if ride.quest_id else None
    return AdventureEntry(
        ride=service.ride_out(ride),
        quest=quest_out(quest).model_dump(mode="json") if quest else None,
        xpAwarded=int(result.get("xpAwarded", 0)),
        discoveries=result.get("discoveries", []),
        newTerritoryMeters=float(result.get("newTerritoryMeters", 0.0)),
        newCells=int(result.get("newCells", 0)),
        levelUps=result.get("levelUps", []),
        notes=ride.notes,
        entry=result.get("entry"),
        entryWritten=result.get("entryWritten"),
    )


@router.get("/adventures", response_model=Page[AdventureEntry])
async def adventures(
    user: CurrentUser, db: DBDep, limit: int | None = None, cursor: str | None = None
) -> Page[AdventureEntry]:
    rows, next_cursor = await service.list_rides(db, user, clamp_limit(limit), cursor)
    return Page(
        items=[await entry(db, r) for r in rows if r.status in ("PROCESSED", "FLAGGED")],
        nextCursor=next_cursor,
    )


class AtlasTraceOut(APIModel):
    rideId: str
    activity: str
    # The day it began (the phone's own day when it said), "2026-10-05".
    date: str
    # Encoded (Google polyline, 1e5), at most 200 points.
    polyline: str


class AtlasDayOut(APIModel):
    date: str
    journeys: int
    distanceMeters: float


class AtlasFirstOut(APIModel):
    # FIRST_CREATURE, FIRST_LEGEND, FIRST_RUNE, LONGEST_JOURNEY, HIGHEST_POINT or
    # FIRST_DISTRICT_COMPLETE.
    kind: str
    date: str
    text: str


class AtlasYearOut(APIModel):
    year: int
    journeys: int
    distanceMeters: float
    newTiles: int
    creaturesDefeated: int
    legendsDefeated: int
    runesCut: int
    # Districts that became yours this year.
    districtsYours: int
    # The deed titles reached this year, in order.
    deedsReached: list[str]
    firsts: list[AtlasFirstOut]


class AtlasOut(APIModel):
    traces: list[AtlasTraceOut]
    days: list[AtlasDayOut]
    year: AtlasYearOut


@router.get("/atlas", response_model=AtlasOut)
async def atlas(user: CurrentUser, db: DBDep, year: int | None = Query(default=None, ge=2000, le=2100)) -> AtlasOut:
    """The Atlas (0.9.0): every journey of the year as a trace (at most 1,000, the
    newest), the days with a journey (the calendar), and the year's numbers and
    firsts. `year` defaults to this one."""
    from app.core.security import utcnow
    from app.rides.atlas import atlas as build

    return AtlasOut(**await build(db, user.id, year or utcnow().year))


@router.get("/stats", response_model=ExplorationStats)
async def stats(user: CurrentUser, db: DBDep, settings: SettingsDep) -> ExplorationStats:
    return await exploration_stats(db, user.id, settings.h3_resolution)
