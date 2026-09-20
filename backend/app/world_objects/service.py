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
from app.core.errors import NotFound
from app.core.geo import haversine_m
from app.core.logging import get_logger
from app.core.security import utcnow
from app.db.spatial import bbox_filter
from app.discoveries.service import nearby as discoveries_nearby
from app.economy import service as economy
from app.economy.rules import load_ac_rules
from app.exploration.cells import cell_center, cell_for, frontier_cells
from app.exploration.service import known_cells
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

    def claimed_of(self, kind: str) -> list[WorldObject]:
        return [o for o in self.claimed if o.kind == kind]

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
                }
                for o in self.claimed
            ],
            "missed": [
                {"id": str(o.id), "kind": o.kind, "name": o.payload.get("name", o.kind.title()), "reason": reason}
                for o, reason in self.missed
            ],
        }


def to_out(obj: WorldObject) -> WorldObjectOut:
    payload = obj.payload or {}
    monster = None
    if obj.kind == "MONSTER":
        monster = MonsterOut(
            hp=int(payload.get("hp", 100)),
            flavour=payload.get("flavour"),
            killMethods=[KillMethodOut(**m) for m in payload.get("killMethods", [])],
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
        verdict = _fight(obj, points, coords, activity, new_cells, encounter_events, resolution)
        if verdict is None:
            outcome.missed.append((obj, "UNBEATEN"))
        else:
            _claim(obj, ride, ended, verdict)
            outcome.claimed.append(obj)
    return outcome


def _claim(obj: WorldObject, ride: Any, ended: datetime, detail: dict[str, Any]) -> None:
    obj.status = "CLAIMED"
    obj.claimed_at = ended
    obj.claimed_ride_id = ride.id
    obj.claim_payload = detail


def _fight(
    obj: WorldObject,
    points: list[CleanPoint],
    coords: list[tuple[float, float]],
    activity: str,
    new_cells: set[str],
    events: list[dict[str, Any]],
    resolution: int,
) -> dict[str, Any] | None:
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
    return None
