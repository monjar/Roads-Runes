from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.characters.service import get_character
from app.core.deps import CurrentUser, DBDep, SettingsDep, get_job_queue, get_llm, get_router_client
from app.core.feature_flags import require_flag
from app.core.pagination import Page, clamp_limit
from app.quests import service, story
from app.quests.schemas import (
    QuestCompleteRequest,
    QuestCompletion,
    QuestGenerateRequest,
    QuestOut,
    QuestProgressRequest,
    QuestStartRequest,
    StoryArcOut,
)
from app.routing import service as routing
from app.routing.schemas import RouteOptionOut

router = APIRouter(prefix="/quests", tags=["quests"])


@router.get("", response_model=Page[QuestOut])
async def list_quests(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    llm: Annotated[object, Depends(get_llm)],
    latitude: float | None = Query(default=None, ge=-90, le=90),
    longitude: float | None = Query(default=None, ge=-180, le=180),
    status: str | None = None,
    limit: int | None = None,
    activity: str | None = None,
) -> Page[QuestOut]:
    size = clamp_limit(limit)
    if latitude is not None and longitude is not None and status in (None, "AVAILABLE"):
        character = await get_character(db, user)
        await service.ensure_available(db, settings, llm, user, character, latitude, longitude, activity=activity)  # type: ignore[arg-type]
    rows = await service.list_quests(db, user, status, latitude, longitude, size)
    return Page(items=[service.quest_out(q) for q in rows], nextCursor=None)


@router.post("/generate", response_model=Page[QuestOut])
async def generate(
    payload: QuestGenerateRequest,
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    llm: Annotated[object, Depends(get_llm)],
) -> Page[QuestOut]:
    character = await get_character(db, user)
    quests = await service.generate_quests(
        db,
        settings,
        llm,
        user,
        character,
        payload.latitude,
        payload.longitude,
        payload.count,
        payload.request,
        activity=payload.activity,
    )  # type: ignore[arg-type]
    return Page(items=[service.quest_out(q) for q in quests], nextCursor=None)


@router.get("/story", response_model=list[StoryArcOut])
async def story_arcs(user: CurrentUser, db: DBDep, settings: SettingsDep) -> list[StoryArcOut]:
    """The authored arcs and where the rider stands in each.

    Every arc is returned, locked ones included: an arc the rider cannot start yet
    is the reason to come back, and hiding it hides the game.
    """
    require_flag(settings, "story_quests")
    character = await get_character(db, user)
    return [StoryArcOut(**arc) for arc in await story.progress(db, user, character)]


@router.get("/{quest_id}", response_model=QuestOut)
async def get(quest_id: uuid.UUID, user: CurrentUser, db: DBDep) -> QuestOut:
    return service.quest_out(await service.get_quest(db, user, quest_id))


@router.get("/{quest_id}/route", response_model=RouteOptionOut)
async def route(
    quest_id: uuid.UUID,
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    engine: Annotated[object, Depends(get_router_client)],
    llm: Annotated[object, Depends(get_llm)],
) -> RouteOptionOut:
    """The quest's fixed route, generated on first request and stable afterwards."""
    chosen, components = await routing.quest_route(db, settings, engine, llm, user, quest_id)  # type: ignore[arg-type]
    return routing.route_out(chosen, components)


@router.post("/{quest_id}/accept", response_model=QuestOut)
async def accept(quest_id: uuid.UUID, user: CurrentUser, db: DBDep) -> QuestOut:
    return service.quest_out(await service.accept(db, user, quest_id))


@router.post("/{quest_id}/start", response_model=QuestOut)
async def start(quest_id: uuid.UUID, payload: QuestStartRequest | None, user: CurrentUser, db: DBDep) -> QuestOut:
    return service.quest_out(await service.start(db, user, quest_id, payload.rideId if payload else None))


@router.post("/{quest_id}/progress", response_model=QuestOut)
async def progress(quest_id: uuid.UUID, payload: QuestProgressRequest, user: CurrentUser, db: DBDep) -> QuestOut:
    return service.quest_out(await service.record_progress(db, user, quest_id, payload.events))


@router.post("/{quest_id}/complete", response_model=QuestCompletion)
async def complete(
    quest_id: uuid.UUID,
    payload: QuestCompleteRequest | None,
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    jobs: Annotated[object, Depends(get_job_queue)],
) -> QuestCompletion:
    from app.rides.processing import complete_quest_with_ride, complete_quest_without_ride

    quest = await service.get_quest(db, user, quest_id)
    ride_id = payload.rideId if payload else None
    if ride_id is not None:
        result = await complete_quest_with_ride(db, settings, user, quest, ride_id)
    else:
        result = await complete_quest_without_ride(db, settings, user, quest)
    return QuestCompletion(**result)


@router.post("/{quest_id}/abandon", response_model=QuestOut)
async def abandon(quest_id: uuid.UUID, user: CurrentUser, db: DBDep) -> QuestOut:
    return service.quest_out(await service.abandon(db, user, quest_id))
