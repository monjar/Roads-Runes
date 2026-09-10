from __future__ import annotations

from fastapi import APIRouter, Query

from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.schemas import Coordinate
from app.discoveries.service import nearby as discoveries_nearby
from app.discoveries.service import summaries, user_found
from app.exploration import service
from app.exploration.schemas import ExplorationOut, ExplorationStats, QuestMarker, WorldOut
from app.quests.service import list_quests

router = APIRouter(prefix="/world", tags=["world"])


@router.get("", response_model=WorldOut)
async def world(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    latitude: float = Query(ge=-90, le=90),
    longitude: float = Query(ge=-180, le=180),
    radiusMeters: float = Query(default=5000, ge=200, le=50000),
) -> WorldOut:
    cells = (
        await service.cells_near(db, user.id, latitude, longitude, radiusMeters, settings.h3_resolution)
        if settings.flags.get("fog_of_war", True)
        else []
    )
    discoveries = await discoveries_nearby(db, latitude, longitude, radiusMeters, limit=100)
    found = await user_found(db, user.id, [d.id for d in discoveries])
    quests = await list_quests(db, user, None, latitude, longitude, 30)
    markers = []
    for q in quests:
        if q.status not in ("AVAILABLE", "ACCEPTED", "ACTIVE"):
            continue
        target = next((o for o in q.objectives if o.latitude is not None), None)
        if target is None:
            continue
        markers.append(
            QuestMarker(
                questId=q.id,
                title=q.title,
                latitude=target.latitude,
                longitude=target.longitude,
                difficulty=q.difficulty,
                questType=q.quest_type,
                status=q.status,
            )
        )
    return WorldOut(
        center=Coordinate(latitude=latitude, longitude=longitude),
        h3Resolution=settings.h3_resolution,
        cells=cells,
        discoveries=[d.model_dump(mode="json") for d in summaries(discoveries, found)],
        questMarkers=markers,
        featureFlags=settings.flags,
    )


@router.get("/exploration", response_model=ExplorationOut)
async def exploration(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    minLat: float = Query(ge=-90, le=90),
    minLon: float = Query(ge=-180, le=180),
    maxLat: float = Query(ge=-90, le=90),
    maxLon: float = Query(ge=-180, le=180),
) -> ExplorationOut:
    return ExplorationOut(
        h3Resolution=settings.h3_resolution,
        cells=await service.cells_in_bbox(db, user.id, minLat, minLon, maxLat, maxLon),
    )


@router.get("/exploration/stats", response_model=ExplorationStats)
async def stats(user: CurrentUser, db: DBDep, settings: SettingsDep) -> ExplorationStats:
    return await service.stats(db, user.id, settings.h3_resolution)
