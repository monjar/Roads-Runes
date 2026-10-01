from __future__ import annotations

import uuid

from fastapi import APIRouter, Query

from app.characters.service import get_character, get_rider_profile
from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.errors import NotFound
from app.core.schemas import APIModel
from app.economy import service as economy
from app.quests import service as quests
from app.world_objects import service
from app.world_objects.schemas import ClaimIn, ClaimResultOut, WorldObjectOut

router = APIRouter(prefix="/world/objects", tags=["world"])


class LureIn(APIModel):
    latitude: float
    longitude: float


@router.get("", response_model=list[WorldObjectOut])
async def objects(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    latitude: float = Query(ge=-90, le=90),
    longitude: float = Query(ge=-180, le=180),
    radiusMeters: float = Query(default=6000, ge=200, le=50000),
) -> list[WorldObjectOut]:
    character = await get_character(db, user)
    profile = await get_rider_profile(db, user.id)
    live = await service.ensure_spawned(
        db,
        settings,
        user.id,
        latitude,
        longitude,
        radiusMeters,
        character_class=character.character_class,
        activity=profile.default_activity,
    )
    return [service.to_out(o) for o in live]


@router.post("/lure", response_model=list[WorldObjectOut])
async def lure(payload: LureIn, user: CurrentUser, db: DBDep, settings: SettingsDep) -> list[WorldObjectOut]:
    character = await get_character(db, user)
    profile = await get_rider_profile(db, user.id)
    live = await service.lure(
        db,
        settings,
        user.id,
        payload.latitude,
        payload.longitude,
        character_class=character.character_class,
        activity=profile.default_activity,
    )
    return [service.to_out(o) for o in live]


@router.get("/bounty", response_model=WorldObjectOut)
async def bounty(user: CurrentUser, db: DBDep) -> WorldObjectOut:
    """Today's bounty, spawned on the first look at the world today; 404 until then, or once it is gone."""
    found = await service.todays_bounty(db, user.id)
    if found is None:
        raise NotFound("No bounty today yet", code="NO_BOUNTY")
    return service.to_out(found)


@router.get("/{object_id}", response_model=WorldObjectOut)
async def one(object_id: uuid.UUID, user: CurrentUser, db: DBDep) -> WorldObjectOut:
    return service.to_out(await service.get_object(db, user.id, object_id))


@router.post("/{object_id}/claim", response_model=ClaimResultOut)
async def claim(
    object_id: uuid.UUID, payload: ClaimIn, user: CurrentUser, db: DBDep, settings: SettingsDep
) -> ClaimResultOut:
    """Open a chest or pick up a piece from beside it. 409 when it is out of reach
    (OBJECT_OUT_OF_RANGE), gone (OBJECT_GONE) or a monster (OBJECT_NOT_CLAIMABLE)."""
    obj, awarded = await service.claim_by_tap(
        db, user.id, object_id, payload.latitude, payload.longitude, payload.horizontalAccuracyMeters
    )
    finished = await quests.on_object_claimed(db, settings, user, obj)
    return ClaimResultOut(
        object=service.to_out(obj),
        acAwarded=awarded,
        walletBalance=await economy.balance(db, user.id),
        questCompleted=quests.quest_out(finished).model_dump(mode="json") if finished else None,
    )
