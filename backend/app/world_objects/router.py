from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.characters.service import get_character, get_rider_profile, maybe_character
from app.core.deps import CurrentUser, DBDep, SettingsDep
from app.core.errors import NotFound
from app.core.feature_flags import require_flag
from app.core.logging import get_logger
from app.core.schemas import APIModel
from app.core.security import utcnow
from app.discoveries import osm_import
from app.discoveries.schemas import DiscoverySummary
from app.discoveries.service import nearby as discoveries_nearby
from app.discoveries.service import summaries, user_found
from app.economy import service as economy
from app.economy.rules import load_ac_rules
from app.inventory import service as inventory
from app.progression.engine import XPLine, cap_to_day, claim_lines, load_xp_rules
from app.progression.service import grant, xp_today
from app.quests import service as quests
from app.world_objects import lairs, service
from app.world_objects.schemas import ClaimIn, ClaimResultOut, WorldObjectOut

router = APIRouter(prefix="/world/objects", tags=["world"])
# Ride anywhere (0.9.2): the world round a journey with no route, as it goes.
around_router = APIRouter(prefix="/world", tags=["world"])
log = get_logger(__name__)


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
    # A lair is offered from level 8 (0.8.0); it is one of the world's objects, so it
    # comes back with the rest. A failure here is a map without a lair, never no map.
    try:
        async with db.begin_nested():
            await lairs.ensure_offered(db, settings, character, near=(latitude, longitude))
    except Exception as exc:  # noqa: BLE001
        log.error("lair_offer_failed", error=str(exc)[:200])
    # The places round here are fetched the first time the area is looked at (0.9.2),
    # not only when a quest or a route is planned there; the world spawns on them on a
    # later look (the tile is not counted as checked while they are on their way).
    await _import_places(settings, latitude, longitude)
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
    # Coins it costs: 0 when a lamp from the bag would be used (0.7.2).
    cost: int
    placeName: str | None = None
    code: str | None = None
    message: str | None = None
    # Lamps in the bag (0.7.2); one is used before coins.
    lampsInBag: int = 0


@router.get("/lure", response_model=LampCheckOut)
async def lure_check(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    latitude: float = Query(ge=-90, le=90),
    longitude: float = Query(ge=-180, le=180),
) -> LampCheckOut:
    spot = await service.lamp_spot(db, settings, user.id, latitude, longitude)
    lamps = (await inventory.consumable_counts(db, await maybe_character(db, user.id))).get("LAMP", 0)
    ok = spot.place is not None
    return LampCheckOut(
        ok=ok,
        cost=0 if lamps else int(load_ac_rules()["lure"]["costAC"]),
        placeName=spot.place.name if spot.place is not None else None,
        code=spot.code,
        message=spot.message if not ok else ("Uses a lamp from your bag." if lamps else None),
        lampsInBag=lamps,
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
        raise NotFound("No bounty right now. A new one comes each day when you open the map.", code="NO_BOUNTY")
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
    sheet = await inventory.sheet_for(db, character)
    obj, awarded, set_done = await service.claim_by_tap(
        db,
        user.id,
        object_id,
        payload.latitude,
        payload.longitude,
        payload.horizontalAccuracyMeters,
        coin_pct=sheet.coin_pct,
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
    # A chest opened by hand may hold an item (0.7.2), as one passed on a ride does,
    # and a tier-3 one sometimes a treasure map besides (0.8.0).
    found = await inventory.drop_for(db, character, obj, sheet=sheet)
    treasure_map = await inventory.map_for(db, character, obj)
    finished = await quests.on_object_claimed(db, settings, user, obj)
    return ClaimResultOut(
        object=service.to_out(obj, await service.pieces_owned(db, user.id)),
        acAwarded=awarded,
        walletBalance=await economy.balance(db, user.id),
        questCompleted=quests.quest_out(finished).model_dump(mode="json") if finished else None,
        xpAwarded=reward.xp_awarded,
        levelUps=reward.level_ups,
        setCompleted=set_done,
        itemFound=found,
        itemsFound=[f for f in (found, treasure_map) if f],
    )


async def _import_places(settings: Any, latitude: float, longitude: float) -> None:
    try:
        await osm_import.ensure_pois(settings, latitude, longitude, wait=False)
    except Exception as exc:  # noqa: BLE001 - a map without new places, never no map
        log.error("poi_import_start_failed", error=str(exc)[:200])


class AroundOut(APIModel):
    """The world round a journey with no route (0.9.2): the things there, the places
    there (for the ride to say when one is found), and whether places round here are
    still being fetched, so the phone asks again sooner."""

    objects: list[WorldObjectOut]
    places: list[DiscoverySummary]
    importing: bool = False


AROUND_RADIUS_M = 6000.0
AROUND_PLACES_M = 3000.0


@around_router.get("/around", response_model=AroundOut)
async def around(
    user: CurrentUser,
    db: DBDep,
    settings: SettingsDep,
    latitude: float = Query(ge=-90, le=90),
    longitude: float = Query(ge=-180, le=180),
    rideId: uuid.UUID | None = None,
    radiusMeters: float = Query(default=AROUND_RADIUS_M, ge=200, le=8000),
) -> AroundOut:
    """Ride anywhere: what is round the rider now. For a journey still recording it
    may also place things here, at most once a minute and 20 times a journey; anyone
    else is only shown what is already there (`GET /world/objects` places)."""
    from app.rides.models import Ride

    require_flag(settings, "ride_anywhere")
    character = await get_character(db, user)
    await _import_places(settings, latitude, longitude)
    ride = (
        await db.scalar(select(Ride).where(Ride.id == rideId, Ride.user_id == user.id, Ride.status == "RECORDING"))
        if rideId is not None
        else None
    )
    now = utcnow()
    if ride is not None and service.ride_may_spawn(ride.id, now):
        service.ride_spawned(ride.id, now)
        live = await service.ensure_spawned(
            db,
            settings,
            user.id,
            latitude,
            longitude,
            radiusMeters,
            character_class=character.character_class,
            activity=ride.activity,
        )
    else:
        await service.expire_stale(db, user.id)
        live = await service.live_objects(db, user.id, latitude, longitude, radiusMeters)
    places = await discoveries_nearby(db, latitude, longitude, min(radiusMeters, AROUND_PLACES_M), limit=100)
    found = await user_found(db, user.id, [d.id for d in places])
    owned = await service.pieces_owned(db, user.id)
    return AroundOut(
        objects=[service.to_out(o, owned) for o in live if o.kind != "LAIR"],
        places=summaries(places, found),
        importing=await service.import_due(db, settings, latitude, longitude),
    )
