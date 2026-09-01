from __future__ import annotations

from typing import Any

from fastapi import APIRouter
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


@router.get("/stats", response_model=ExplorationStats)
async def stats(user: CurrentUser, db: DBDep, settings: SettingsDep) -> ExplorationStats:
    return await exploration_stats(db, user.id, settings.h3_resolution)
