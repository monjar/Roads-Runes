from __future__ import annotations

import uuid

from fastapi import APIRouter, Query

from app.characters.service import get_character, get_rider_profile
from app.characters.sheet import build_sheet
from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.errors import NotFound
from app.core.schemas import APIModel
from app.economy import service as economy
from app.economy.rules import load_ac_rules
from app.inventory import service as inventory
from app.progression.engine import XPLine, cap_to_day, claim_lines, load_xp_rules
from app.progression.service import grant, xp_today
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
    owned = await service.pieces_owned(db, user.id)
    return [service.to_out(o, owned) for o in live]


class LampCheckOut(APIModel):
    """Whether a lamp would bring something here, asked before any coins are spent."""

    ok: bool
    cost: int
    placeName: str | None = None
    code: str | None = None
    message: str | None = None


@router.get("/lure", response_model=LampCheckOut)
async def lure_check(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    latitude: float = Query(ge=-90, le=90),
    longitude: float = Query(ge=-180, le=180),
) -> LampCheckOut:
    spot = await service.lamp_spot(db, settings, user.id, latitude, longitude)
    return LampCheckOut(
        ok=spot.place is not None,
        cost=int(load_ac_rules()["lure"]["costAC"]),
        placeName=spot.place.name if spot.place is not None else None,
        code=spot.code,
        message=spot.message,
    )


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
    character = await get_character(db, user)
    obj, awarded, set_done = await service.claim_by_tap(
        db,
        user.id,
        object_id,
        payload.latitude,
        payload.longitude,
        payload.horizontalAccuracyMeters,
        coin_pct=build_sheet(character).coin_pct,
    )
    # Worth doing for its own sake too: the same XP a ride past it would have given,
    # within what a day may earn (a ride has its own cap; taps had none).
    lines = claim_lines([(obj.kind, obj.tier, obj.bounty)])
    if set_done is not None:
        lines.append(XPLine("SET_COMPLETED", load_xp_rules()["setCompleted"], {"set": set_done["name"]}))
    lines = cap_to_day(lines, await xp_today(db, character))
    reward = await grant(db, character, lines)
    # A rune stone picked up by hand is held, or a stone towards the next rank.
    rune_id = inventory.rune_of_piece(obj.payload) if obj.kind == "COLLECTABLE" else None
    if rune_id:
        await inventory.add_stone(db, character, rune_id, key=f"stone:{obj.id}")
    finished = await quests.on_object_claimed(db, settings, user, obj)
    return ClaimResultOut(
        object=service.to_out(obj, await service.pieces_owned(db, user.id)),
        acAwarded=awarded,
        walletBalance=await economy.balance(db, user.id),
        questCompleted=quests.quest_out(finished).model_dump(mode="json") if finished else None,
        xpAwarded=reward.xp_awarded,
        levelUps=reward.level_ups,
        setCompleted=set_done,
    )
