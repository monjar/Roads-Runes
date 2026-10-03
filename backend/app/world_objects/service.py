"""Spawning, finding and claiming the objects in one player's world."""

from __future__ import annotations

import asyncio
import json
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.activity import SPEED_CAP_MPS, normalise
from app.core.errors import Conflict, NotFound
from app.core.geo import haversine_m
from app.core.logging import get_logger
from app.core.security import utcnow
from app.db.spatial import bbox_filter
from app.discoveries.service import nearby as discoveries_nearby
from app.economy import service as economy
from app.economy.rules import load_ac_rules
from app.exploration.cells import cell_center, cell_for, frontier_cells
from app.exploration.service import known_cells
from app.lore import catalog as lore
from app.rides.validation import CleanPoint
from app.world_objects import claims
from app.world_objects.models import WorldObject
from app.world_objects.schemas import KillMethodOut, MonsterOut, WorldObjectOut
from app.world_objects.spawner import Anchor, SpawnPlan, day_seed, plan_spawns, tile_of

# Spawning is checked at most once per (user, tile, day) per process; the map is
# asked for the world on every pan, and the answer does not change within a day.
log = get_logger(__name__)

_checked: OrderedDict[tuple[str, str, str], bool] = OrderedDict()
_CHECKED_LIMIT = 4096
_locks: dict[str, asyncio.Lock] = {}


@lru_cache(maxsize=1)
def load_config() -> dict[str, Any]:
    return json.loads((Path(__file__).parent / "config" / "world_objects.json").read_text())


def forget_checks() -> None:
    """Tests, and a lure: the next look at the world spawns again."""
    _checked.clear()


@dataclass
class ClaimOutcome:
    claimed: list[WorldObject] = field(default_factory=list)
    missed: list[tuple[WorldObject, str]] = field(default_factory=list)
    # Opened or picked up by hand while this ride was under way: already paid for,
    # so they earn nothing here, but they count towards what the ride's quest asked.
    tapped: list[WorldObject] = field(default_factory=list)

    def claimed_of(self, kind: str) -> list[WorldObject]:
        return [o for o in self.claimed if o.kind == kind]

    # How near an unbeaten monster came to being beaten, by its id: the closest of
    # the ways it could have fallen, so the summary can say what it would have taken.
    attempts: dict[uuid.UUID, dict[str, Any]] = field(default_factory=dict)
    # The pieces of each set the player holds once this ride's are counted.
    owned: dict[str, set[str]] = field(default_factory=dict)
    # Sets this ride finished: [{"id", "name", "bonusAC"}].
    sets_completed: list[dict[str, Any]] = field(default_factory=list)

    def counted_of(self, kind: str) -> list[WorldObject]:
        return [o for o in [*self.claimed, *self.tapped] if o.kind == kind]

    def to_dict(self) -> dict[str, Any]:
        return {
            "claimed": [
                {
                    "id": str(o.id),
                    "kind": o.kind,
                    "name": o.payload.get("name", o.kind.title()),
                    "tier": o.tier,
                    "rewardAC": o.reward_ac,
                    "method": (o.claim_payload or {}).get("method"),
                    **set_fields(o, self.owned),
                }
                for o in self.claimed
            ],
            "missed": [
                {
                    "id": str(o.id),
                    "kind": o.kind,
                    "name": o.payload.get("name", o.kind.title()),
                    "reason": reason,
                    "expiresAt": o.expires_at.isoformat(),
                    **({"attempt": self.attempts[o.id]} if o.id in self.attempts else {}),
                }
                for o, reason in self.missed
            ],
            "setsCompleted": self.sets_completed,
        }


# --- sets --------------------------------------------------------------------


def set_catalog() -> dict[str, dict[str, Any]]:
    return {s["id"]: s for s in load_config().get("collectableSets", [])}


def set_fields(obj: WorldObject, owned: dict[str, set[str]] | None = None) -> dict[str, Any]:
    """A piece's set: its name and size, and how many different pieces are held."""
    known = set_catalog().get(str((obj.payload or {}).get("setId") or ""))
    if obj.kind != "COLLECTABLE" or known is None:
        return {}
    fields: dict[str, Any] = {
        "setId": known["id"],
        "piece": obj.payload.get("piece"),
        "setName": known["name"],
        "setSize": len(known["pieces"]),
    }
    if owned is not None:
        held = owned.get(known["id"], set())
        fields["setOwned"] = len(held)
        fields["pieceOwned"] = str(obj.payload.get("piece")) in held
    return fields


async def pieces_owned(db: AsyncSession, user_id: uuid.UUID) -> dict[str, set[str]]:
    """The different pieces of each set the player has picked up. A second Raido is
    ten coins and nothing more: a set is its pieces, not a count of finds."""
    rows = await db.execute(
        select(WorldObject.payload).where(
            WorldObject.user_id == user_id, WorldObject.kind == "COLLECTABLE", WorldObject.status == "CLAIMED"
        )
    )
    owned: dict[str, set[str]] = {}
    for (payload,) in rows:
        set_id, piece = (payload or {}).get("setId"), (payload or {}).get("piece")
        if set_id and piece:
            owned.setdefault(str(set_id), set()).add(str(piece))
    return owned


def newly_completed(before: dict[str, set[str]], after: dict[str, set[str]]) -> list[dict[str, Any]]:
    """Sets that were short before and are whole now, with the purse for each."""
    bonus = int(load_ac_rules().get("collectableSetBonus", 0))
    done = []
    for set_id, known in set_catalog().items():
        size = len(known["pieces"])
        if len(before.get(set_id, set())) < size <= len(after.get(set_id, set())):
            done.append({"id": set_id, "name": known["name"], "bonusAC": bonus})
    return done


def to_out(obj: WorldObject, owned: dict[str, set[str]] | None = None) -> WorldObjectOut:
    payload = obj.payload or {}
    in_set = set_fields(obj, owned)
    monster = None
    if obj.kind == "MONSTER":
        species_id = lore.species_of(payload)
        species = lore.species_by_id().get(species_id or "")
        monster = MonsterOut(
            hp=int(payload.get("hp", 100)),
            flavour=payload.get("flavour"),
            killMethods=[KillMethodOut(**m) for m in payload.get("killMethods", [])],
            speciesId=species_id,
            sigil=dict(species["sigil"]) if species else None,
        )
    return WorldObjectOut(
        id=obj.id,
        kind=obj.kind,
        status=obj.status,
        tier=obj.tier,
        latitude=obj.latitude,
        longitude=obj.longitude,
        name=str(payload.get("name", obj.kind.title())),
        anchorName=payload.get("anchorName"),
        bounty=obj.bounty,
        rewardAC=obj.reward_ac,
        expiresAt=obj.expires_at,
        claimedAt=obj.claimed_at,
        monster=monster,
        setId=payload.get("setId"),
        piece=payload.get("piece"),
        setName=in_set.get("setName"),
        setSize=in_set.get("setSize"),
        setOwned=in_set.get("setOwned"),
        pieceOwned=in_set.get("pieceOwned"),
        claimRadiusMeters=load_config()["claimRadiusMeters"].get(obj.kind),
    )


async def expire_stale(db: AsyncSession, user_id: uuid.UUID) -> None:
    now = utcnow()
    rows = (
        await db.execute(
            select(WorldObject).where(
                WorldObject.user_id == user_id, WorldObject.status == "SPAWNED", WorldObject.expires_at < now
            )
        )
    ).scalars()
    for row in rows:
        row.status = "EXPIRED"


async def live_objects(
    db: AsyncSession, user_id: uuid.UUID, latitude: float, longitude: float, radius_m: float
) -> list[WorldObject]:
    stmt = select(WorldObject).where(
        WorldObject.user_id == user_id, WorldObject.status == "SPAWNED", WorldObject.expires_at >= utcnow()
    )
    rows = (await db.execute(bbox_filter(stmt, WorldObject, latitude, longitude, radius_m))).scalars().all()
    return [r for r in rows if haversine_m(latitude, longitude, r.latitude, r.longitude) <= radius_m]


async def get_object(db: AsyncSession, user_id: uuid.UUID, object_id: uuid.UUID) -> WorldObject:
    obj = await db.get(WorldObject, object_id)
    if obj is None or obj.user_id != user_id:
        raise NotFound("Nothing like that here")
    return obj


async def _seeds_like(db: AsyncSession, user_id: uuid.UUID, prefix: str) -> set[str]:
    rows = await db.execute(
        select(WorldObject.seed).where(WorldObject.user_id == user_id, WorldObject.seed.like(f"{prefix}:%"))
    )
    return set(rows.scalars())


async def todays_bounty(db: AsyncSession, user_id: uuid.UUID) -> WorldObject | None:
    return await db.scalar(
        select(WorldObject)
        .where(
            WorldObject.user_id == user_id,
            WorldObject.bounty.is_(True),
            WorldObject.status == "SPAWNED",
            WorldObject.expires_at >= utcnow(),
        )
        .order_by(WorldObject.spawned_at.desc())
    )


async def _persist(
    db: AsyncSession,
    user_id: uuid.UUID,
    plans: list[SpawnPlan],
    now: datetime,
    expiry_days: float,
    resolution: int,
    *,
    expires_at: datetime | None = None,
) -> list[WorldObject]:
    created: list[WorldObject] = []
    for plan in plans:
        obj = WorldObject(
            user_id=user_id,
            kind=plan.kind,
            status="SPAWNED",
            tier=plan.tier,
            anchor_discovery_id=uuid.UUID(plan.anchor.discovery_id),
            latitude=plan.anchor.latitude,
            longitude=plan.anchor.longitude,
            h3_index=plan.anchor.h3_index or cell_for(plan.anchor.latitude, plan.anchor.longitude, resolution),
            seed=plan.seed,
            bounty=plan.bounty,
            reward_ac=plan.reward_ac,
            payload=plan.payload,
            spawned_at=now,
            expires_at=expires_at or (now + timedelta(days=expiry_days)),
        )
        try:
            async with db.begin_nested():
                db.add(obj)
                await db.flush()
        except IntegrityError as exc:
            # Another request spawned this very seed a moment ago; or a place vanished.
            log.info("world_object_spawn_conflict", seed=plan.seed, error=str(exc)[:160])
            continue
        created.append(obj)
    return created


async def ensure_spawned(
    db: AsyncSession,
    settings: Any,
    user_id: uuid.UUID,
    latitude: float,
    longitude: float,
    radius_m: float,
    *,
    character_class: str = "EXPLORER",
    activity: str = "RIDE",
    seed_suffix: str = "",
    force: bool = False,
) -> list[WorldObject]:
    """The live objects around a point, topped up to quota if this is the first look today.

    `latitude`/`longitude` are where the player is: the rings are drawn around them.
    One player is spawned for at a time, so two requests at launch (the map and the
    quest board) cannot both decide the same place is free.
    """
    async with _locks.setdefault(str(user_id), asyncio.Lock()):
        return await _ensure_spawned(
            db,
            settings,
            user_id,
            latitude,
            longitude,
            radius_m,
            character_class=character_class,
            activity=activity,
            seed_suffix=seed_suffix,
            force=force,
        )


async def _ensure_spawned(
    db: AsyncSession,
    settings: Any,
    user_id: uuid.UUID,
    latitude: float,
    longitude: float,
    radius_m: float,
    *,
    character_class: str,
    activity: str,
    seed_suffix: str,
    force: bool,
) -> list[WorldObject]:
    cfg = load_config()
    spawn_radius = float(cfg["spawnRadiusMeters"])
    await expire_stale(db, user_id)
    live = await live_objects(db, user_id, latitude, longitude, max(radius_m, spawn_radius))
    day = utcnow().date().isoformat()
    tile = tile_of(latitude, longitude)
    key = (str(user_id), tile, day)
    if not force and key in _checked:
        return [o for o in live if haversine_m(latitude, longitude, o.latitude, o.longitude) <= radius_m]
    if len(live) < int(cfg["maxLiveInRadius"]):
        anchors = [
            Anchor(str(d.id), d.name, d.category, d.latitude, d.longitude, d.h3_index)
            for d in await discoveries_nearby(db, latitude, longitude, spawn_radius, limit=300)
        ]
        known = await known_cells(db, user_id)
        explored = {h for h, s in known.items() if s == "EXPLORED"}
        frontier = (
            set(
                frontier_cells(
                    explored, settings.h3_resolution, cell_for(latitude, longitude, settings.h3_resolution), 12
                )
            )
            if explored
            else set()
        )
        taken = {str(o.anchor_discovery_id) for o in live if o.anchor_discovery_id}
        occupied = [(o.latitude, o.longitude) for o in live]
        seed = day_seed(user_id, day, tile, seed_suffix)
        # Slots already used today (claimed, expired or live) so a replacement gets a
        # fresh seed; at most twice the quota a day, so a chest is not a chest factory.
        used_seeds = await _seeds_like(db, user_id, seed)
        # The day's bounty: the first monster placed, twice the purse, gone at midnight. One a
        # day whatever happens to it, so its seed carries no slot.
        bounty_seed = day_seed(user_id, day, "bounty", seed_suffix)
        if not seed_suffix and f"{bounty_seed}:MONSTER:0" not in await _seeds_like(db, user_id, bounty_seed):
            taken = {str(o.anchor_discovery_id) for o in live if o.anchor_discovery_id}
            bounty = plan_spawns(
                seed=bounty_seed,
                kind="MONSTER",
                indices=[0],
                anchors=anchors,
                taken_anchor_ids=taken,
                occupied=[(o.latitude, o.longitude) for o in live],
                cfg=cfg,
                ac_rules=load_ac_rules(),
                frontier=frontier,
                known=known,
                character_class=character_class,
                activity=normalise(activity),
                centre=(latitude, longitude),
                bounty=True,
            )
            end_of_day = datetime.combine(utcnow().date() + timedelta(days=1), datetime.min.time(), tzinfo=UTC)
            live += await _persist(db, user_id, bounty, utcnow(), 0.0, settings.h3_resolution, expires_at=end_of_day)
        # The bounty has taken a place; the rest must not land on top of it.
        taken = {str(o.anchor_discovery_id) for o in live if o.anchor_discovery_id}
        occupied = [(o.latitude, o.longitude) for o in live]
        room = int(cfg["maxLiveInRadius"]) - len(live)
        plans: list[SpawnPlan] = []
        # In a village with six places the first kind used to take them all. Each kind
        # gets its share of what there is, and at least one if it is owed any.
        owed = {k: max(0, int(q) - sum(1 for o in live if o.kind == k)) for k, q in cfg["quota"].items()}
        places = max(0, min(room, len(anchors) - len(live)))
        total_owed = sum(owed.values())
        if total_owed > places > 0:
            owed = {k: (max(1, v * places // total_owed) if v else 0) for k, v in owed.items()}
        for kind in cfg["quota"]:
            deficit = min(room, owed[kind])
            if deficit <= 0:
                continue
            free_slots = [i for i in range(2 * int(cfg["quota"][kind])) if f"{seed}:{kind}:{i}" not in used_seeds]
            if not free_slots:
                continue
            batch = plan_spawns(
                seed=seed,
                kind=kind,
                indices=free_slots[:deficit],
                anchors=anchors,
                taken_anchor_ids=taken | {p.anchor.discovery_id for p in plans},
                occupied=occupied + [(p.anchor.latitude, p.anchor.longitude) for p in plans],
                cfg=cfg,
                ac_rules=load_ac_rules(),
                frontier=frontier,
                known=known,
                character_class=character_class,
                activity=normalise(activity),
                centre=(latitude, longitude),
            )
            plans.extend(batch)
            room -= len(batch)
        live += await _persist(db, user_id, plans, utcnow(), float(cfg["expiryDays"]), settings.h3_resolution)
    _checked[key] = True
    while len(_checked) > _CHECKED_LIMIT:
        _checked.popitem(last=False)
    return [o for o in live if haversine_m(latitude, longitude, o.latitude, o.longitude) <= radius_m]


async def lure(
    db: AsyncSession,
    settings: Any,
    user_id: uuid.UUID,
    latitude: float,
    longitude: float,
    *,
    character_class: str,
    activity: str,
) -> list[WorldObject]:
    """Coins for company: spawns a fresh set now, whatever the day's seed already gave."""
    cost = int(load_ac_rules()["lure"]["costAC"])
    await economy.debit(db, user_id, cost, "LURE", payload={"latitude": latitude, "longitude": longitude})
    suffix = f"lure:{utcnow().timestamp():.0f}"
    return await ensure_spawned(
        db,
        settings,
        user_id,
        latitude,
        longitude,
        float(load_config()["spawnRadiusMeters"]),
        character_class=character_class,
        activity=activity,
        seed_suffix=suffix,
        force=True,
    )


# --- claiming ------------------------------------------------------------------


async def claim_from_ride(
    db: AsyncSession,
    ride: Any,
    character_class: str,
    points: list[CleanPoint],
    new_cells: set[str],
    encounter_events: list[dict[str, Any]],
    *,
    resolution: int,
    ended: datetime,
) -> ClaimOutcome:
    """Everything the trace passed or beat. Chests and pieces are passed; monsters are fought."""
    outcome = ClaimOutcome()
    if len(points) < 2:
        return outcome
    cfg = load_config()
    lats = [p.latitude for p in points]
    lons = [p.longitude for p in points]
    centre_lat, centre_lon = (min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2
    reach = max(haversine_m(centre_lat, centre_lon, lat, lon) for lat, lon in zip(lats, lons, strict=True)) + 1200
    live = await live_objects(db, ride.user_id, centre_lat, centre_lon, reach)
    coords = [(p.latitude, p.longitude) for p in points]
    activity = normalise(ride.activity)
    held = await pieces_owned(db, ride.user_id)
    for obj in live:
        distance = claims.min_distance_to_path_m(obj.latitude, obj.longitude, coords)
        if obj.kind in ("CHEST", "COLLECTABLE"):
            if distance <= float(cfg["claimRadiusMeters"][obj.kind]) * 1.25:
                _claim(obj, ride, ended, {"method": "PASS", "distanceMeters": round(distance, 1)})
                outcome.claimed.append(obj)
            continue
        if distance > float(cfg["monsterNearMeters"]):
            outcome.missed.append((obj, "NOT_NEAR"))
            continue
        tried: list[dict[str, Any]] = []
        verdict = _fight(obj, points, coords, activity, new_cells, encounter_events, resolution, tried)
        if verdict is None:
            outcome.missed.append((obj, "UNBEATEN"))
            if tried:
                outcome.attempts[obj.id] = max(tried, key=lambda attempt: attempt["progress"])
        else:
            _claim(obj, ride, ended, verdict)
            outcome.claimed.append(obj)
    await db.flush()
    outcome.owned = await pieces_owned(db, ride.user_id)
    outcome.sets_completed = newly_completed(held, outcome.owned)
    return outcome


def _claim(obj: WorldObject, ride: Any | None, ended: datetime, detail: dict[str, Any]) -> None:
    obj.status = "CLAIMED"
    obj.claimed_at = ended
    obj.claimed_ride_id = ride.id if ride is not None else None
    obj.claim_payload = detail


# The same allowance a ride's trace gets, and a little more for a phone that says it
# is only sure to within so many metres.
CLAIM_TOLERANCE = 1.25
TAP_ACCURACY_ALLOWANCE_M = 25.0
# Past this the phone does not know where it is well enough to say "I am beside it".
TAP_MAX_ACCURACY_M = 65.0
# Two things opened by hand further apart than this, faster than a bike could go.
TAP_JUMP_MIN_M = 500.0
TAP_KINDS = {"CHEST": "CHEST_OPENED", "COLLECTABLE": "COLLECTABLE"}


async def claim_by_tap(
    db: AsyncSession,
    user_id: uuid.UUID,
    object_id: uuid.UUID,
    latitude: float,
    longitude: float,
    accuracy_m: float | None,
) -> tuple[WorldObject, int, dict[str, Any] | None]:
    """A chest opened, or a piece picked up, by a player standing beside it.

    A ride claims what its trace passed; this is the other way, for someone who has
    walked up to the thing and reached for it. The position is the phone's word, so
    it is checked for what can be checked: that the phone is sure enough of where it
    is, that it is within reach, and that it has not crossed town in a few seconds
    since the last one. A refusal is a refusal and nothing more ("flag, don't ban").
    """
    obj = await get_object(db, user_id, object_id)
    # Two taps at once must not both find it there.
    await db.refresh(obj, with_for_update=True)
    now = utcnow()
    if obj.kind not in TAP_KINDS:
        raise Conflict("A monster has to be beaten on the move", code="OBJECT_NOT_CLAIMABLE")
    if obj.status != "SPAWNED" or obj.expires_at < now:
        raise Conflict("It has already gone", code="OBJECT_GONE", details={"status": obj.status})
    if accuracy_m is not None and accuracy_m > TAP_MAX_ACCURACY_M:
        raise Conflict(
            "GPS is too weak to tell how close you are",
            code="GPS_TOO_WEAK",
            details={"accuracyMeters": round(accuracy_m, 1)},
        )
    radius = float(load_config()["claimRadiusMeters"][obj.kind])
    distance = haversine_m(latitude, longitude, obj.latitude, obj.longitude)
    if distance > radius * CLAIM_TOLERANCE + min(accuracy_m or 0.0, TAP_ACCURACY_ALLOWANCE_M):
        raise Conflict(
            f"Get within {int(radius)} m of it",
            code="OBJECT_OUT_OF_RANGE",
            details={"distanceMeters": round(distance, 1), "radiusMeters": radius},
        )
    last = await db.scalar(
        select(WorldObject)
        .where(
            WorldObject.user_id == user_id,
            WorldObject.status == "CLAIMED",
            WorldObject.claimed_ride_id.is_(None),
            WorldObject.claimed_at.is_not(None),
        )
        .order_by(WorldObject.claimed_at.desc())
        .limit(1)
    )
    where = last.claim_payload or {} if last is not None else {}
    if last is not None and last.claimed_at is not None and "latitude" in where:
        jump = haversine_m(latitude, longitude, float(where["latitude"]), float(where["longitude"]))
        seconds = max(1.0, (now - last.claimed_at).total_seconds())
        if jump > TAP_JUMP_MIN_M and jump / seconds > max(SPEED_CAP_MPS.values()):
            log.warning("world_object_claim_too_fast", user=str(user_id), meters=int(jump), seconds=int(seconds))
            raise Conflict("You cannot have got here that fast", code="CLAIM_TOO_FAST")
    held = await pieces_owned(db, user_id)
    _claim(
        obj,
        None,
        now,
        {"method": "TAP", "distanceMeters": round(distance, 1), "latitude": latitude, "longitude": longitude},
    )
    await db.flush()
    finished = next(iter(newly_completed(held, await pieces_owned(db, user_id))), None)
    if finished is not None and finished["bonusAC"] > 0:
        await economy.credit(
            db, user_id, finished["bonusAC"], "SET_COMPLETED", object_id=obj.id, payload={"set": finished["name"]}
        )
    if obj.reward_ac > 0:
        await economy.credit(
            db,
            user_id,
            obj.reward_ac,
            "BOUNTY" if obj.bounty else TAP_KINDS[obj.kind],
            object_id=obj.id,
            payload={"objectId": str(obj.id), "name": obj.payload.get("name"), "method": "TAP"},
        )
    await db.flush()
    log.info("world_object_claimed", user=str(user_id), kind=obj.kind, method="TAP", meters=round(distance, 1))
    return obj, obj.reward_ac + (finished["bonusAC"] if finished else 0), finished


async def tapped_during(db: AsyncSession, user_id: uuid.UUID, started: datetime, ended: datetime) -> list[WorldObject]:
    """What the player opened or picked up by hand between these two moments."""
    rows = await db.execute(
        select(WorldObject).where(
            WorldObject.user_id == user_id,
            WorldObject.status == "CLAIMED",
            WorldObject.claimed_ride_id.is_(None),
            WorldObject.claimed_at >= started,
            WorldObject.claimed_at <= ended,
        )
    )
    return list(rows.scalars())


def _fight(
    obj: WorldObject,
    points: list[CleanPoint],
    coords: list[tuple[float, float]],
    activity: str,
    new_cells: set[str],
    events: list[dict[str, Any]],
    resolution: int,
    tried: list[dict[str, Any]] | None = None,
) -> dict[str, Any] | None:
    """The first of the monster's ways that the ride satisfied, or None.

    `tried` collects how near each measurable way came (`progress` is 1.0 at the
    target), so a monster that got away can be told as a near thing and not only
    as a miss. A note not written, or a shape not drawn, has no "nearly".
    """

    def nearly(attempt: dict[str, Any], progress: float) -> None:
        if tried is not None:
            tried.append({**attempt, "progress": round(max(0.0, min(progress, 0.999)), 3)})

    for method in obj.payload.get("killMethods", []):
        name, params = method.get("method"), method.get("params", {})
        if name == "PACE":
            radius = float(params.get("searchRadiusMeters", 1000))
            timed = [claims.TimedPoint(p.timestamp.timestamp(), p.latitude, p.longitude) for p in points]
            near = [haversine_m(obj.latitude, obj.longitude, p.latitude, p.longitude) <= radius for p in points]
            window = claims.best_pace_window(
                timed, float(params["windowMeters"]), speed_cap_mps=SPEED_CAP_MPS.get(activity, 25.0), near=near
            )
            target = float(params["paceSecPerKm"].get(activity, params["paceSecPerKm"].get("RIDE", 150)))
            if window is not None and window.pace_s_per_km <= target:
                return {"method": "PACE", "paceSecPerKm": round(window.pace_s_per_km, 1), "targetSecPerKm": target}
            if window is not None and window.pace_s_per_km > 0:
                nearly(
                    {
                        "method": "PACE",
                        "paceSecPerKm": round(window.pace_s_per_km, 1),
                        "targetSecPerKm": target,
                        "windowMeters": float(params["windowMeters"]),
                    },
                    target / window.pace_s_per_km,
                )
        elif name == "RUNE":
            match = claims.match_rune(
                coords,
                (obj.latitude, obj.longitude),
                threshold=float(params.get("scoreThreshold", 0.22)),
                search_radius_m=float(params.get("searchRadiusMeters", 1000)),
                min_length_m=float(params.get("minLengthMeters", 300)),
                max_length_m=float(params.get("maxLengthMeters", 3000)),
            )
            if match is not None and match.shape == params.get("shape"):
                return {"method": "RUNE", "shape": match.shape, "score": match.score}
        elif name == "CLIMB":
            within = float(params.get("withinMeters", 2000))
            altitudes = [
                p.altitude
                for p in points
                if haversine_m(obj.latitude, obj.longitude, p.latitude, p.longitude) <= within
            ]
            gain = claims.elevation_gain_m(altitudes)
            if gain >= float(params["gainMeters"]):
                return {"method": "CLIMB", "gainMeters": round(gain, 1)}
            nearly(
                {"method": "CLIMB", "gainMeters": round(gain, 1), "targetGainMeters": float(params["gainMeters"])},
                gain / max(1.0, float(params["gainMeters"])),
            )
        elif name == "LORE":
            radius = float(params.get("radiusMeters", 120)) * 1.5
            required = set(params.get("requires", []))
            for event in events:
                if str(event.get("objectId")) != str(obj.id):
                    continue
                lat, lon = event.get("latitude"), event.get("longitude")
                if (
                    lat is not None
                    and lon is not None
                    and haversine_m(obj.latitude, obj.longitude, float(lat), float(lon)) > radius
                ):
                    continue
                have = set()
                if event.get("note"):
                    have.add("note")
                if event.get("photoTaken"):
                    have.add("photo")
                if required <= have:
                    return {"method": "LORE", "parts": sorted(have)}
        elif name == "EXPLORE":
            within = float(params.get("withinMeters", 1500))
            cleared = 0
            for cell in new_cells:
                lat, lon = cell_center(cell)
                if haversine_m(obj.latitude, obj.longitude, lat, lon) <= within:
                    cleared += 1
            if cleared >= int(params["cells"]):
                return {"method": "EXPLORE", "cells": cleared}
            nearly(
                {"method": "EXPLORE", "cells": cleared, "targetCells": int(params["cells"])},
                cleared / max(1, int(params["cells"])),
            )
    return None
