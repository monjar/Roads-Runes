"""Spawning, finding and claiming the objects in one player's world."""

from __future__ import annotations

import asyncio
import json
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from functools import lru_cache
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.activity import SPEED_CAP_MPS, normalise
from app.core.config import get_settings
from app.core.errors import Conflict, NotFound
from app.core.feature_flags import is_enabled
from app.core.geo import haversine_m
from app.core.logging import get_logger
from app.core.security import utcnow
from app.db.spatial import bbox_filter
from app.discoveries.sensitivity import is_sensitive
from app.discoveries.service import nearby as discoveries_nearby
from app.economy import service as economy
from app.economy.rules import load_ac_rules
from app.exploration.cells import cell_center, cell_for, frontier_cells
from app.exploration.service import cells_last_passed, known_cells
from app.inventory import catalog as runes_catalog
from app.inventory import service as inventory
from app.lore import catalog as lore
from app.rides.validation import CleanPoint
from app.world_objects import claims, fight
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
    # Effort is damage (fight.py): one report per thing this ride came near, and
    # what each blow was worth in XP terms: (tier, bounty, share of hold taken).
    effort: bool = False
    fights: list[dict[str, Any]] = field(default_factory=list)
    blows: list[tuple[int, bool, float]] = field(default_factory=list)
    flags: list[str] = field(default_factory=list)
    # Inscribed runes woken on the outing (0.7.0).
    woken: list[str] = field(default_factory=list)

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
            **({"fights": self.fights, "woken": self.woken} if self.effort else {}),
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
        if is_enabled(get_settings(), "effort_combat"):
            # A phone from before effort is damage can never call a win: it is given
            # no old-style way to beat anything, and judges nothing.
            foe = foe_of(obj)
            monster.killMethods = []
            monster.holdMax = round(foe.hold_max)
            monster.holdLeft = round(foe.hold_before)
            monster.wants = list(foe.wants)
            monster.minds = list(foe.minds)
            monster.roadForm = foe.road_form
            monster.rune = (species or {}).get("rune")
            monster.unpassedDays = payload.get("unpassedDays")
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
    rows = list(
        (
            await db.execute(
                select(WorldObject).where(
                    WorldObject.user_id == user_id, WorldObject.status == "SPAWNED", WorldObject.expires_at < now
                )
            )
        ).scalars()
    )
    if not rows:
        return
    # A thing a live story step points at does not leave while the step is open:
    # it waits a day at a time, as the arc waits for the player.
    held = await _held_by_story(db, user_id)
    for row in rows:
        if str(row.id) in held:
            row.expires_at = now + timedelta(days=1)
        else:
            row.status = "EXPIRED"


async def _held_by_story(db: AsyncSession, user_id: uuid.UUID) -> set[str]:
    from app.quests.models import QuestInstance, QuestObjective

    rows = await db.execute(
        select(QuestObjective.extra)
        .join(QuestInstance, QuestObjective.quest_id == QuestInstance.id)
        .where(
            QuestInstance.user_id == user_id,
            QuestInstance.story_quest_id.is_not(None),
            QuestInstance.status.in_(["AVAILABLE", "ACCEPTED", "ACTIVE"]),
            QuestObjective.status != "COMPLETED",
        )
    )
    return {str((extra or {}).get("objectId")) for extra in rows.scalars() if (extra or {}).get("objectId")}


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
        # Nearest first, and enough of them that the outer rings are real: with 300,
        # a city's places ran out a kilometre from the door.
        nearby = await discoveries_nearby(db, latitude, longitude, spawn_radius, limit=900)
        # Nothing is placed at a memorial, a grave, a place of worship, a hospital
        # or anywhere private, and anything already there moves on.
        sensitive = {d.id for d in nearby if is_sensitive(d.name, d.tags)}
        for obj in live:
            if obj.anchor_discovery_id in sensitive and obj.status == "SPAWNED":
                obj.status = "EXPIRED"
        live = [o for o in live if o.status == "SPAWNED"]
        last_passed = await cells_last_passed(db, user_id)
        today = utcnow()
        anchors = [
            Anchor(
                str(d.id),
                d.name,
                d.category,
                d.latitude,
                d.longitude,
                d.h3_index,
                tags=dict(d.tags or {}),
                unpassed_days=(today - last_passed[d.h3_index]).days if d.h3_index in last_passed else None,
            )
            for d in nearby
            if d.id not in sensitive
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
        # The day's bounty: the first monster placed, twice the purse, out for a day and a
        # half or two. One a day whatever happens to it, so its seed carries no slot.
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
            # A day and a half to two days from now, not midnight: a midnight deadline
            # pays for riding after dark, and the server's midnight is UTC.
            low, high = cfg.get("combat", {}).get("bountyLifeHours", [36, 48])
            life = low + (int(bounty_seed[:8], 16) % 1000) / 1000 * (high - low)
            bounty_ends = utcnow() + timedelta(hours=life)
            live += await _persist(db, user_id, bounty, utcnow(), 0.0, settings.h3_resolution, expires_at=bounty_ends)
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
        # Rune stones by ground, pity and Arcane Sight (0.7.0).
        rune_hint = await inventory.spawn_hint(db, user_id)
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
                runes=rune_hint,
            )
            plans.extend(batch)
            room -= len(batch)
        live += await _persist(db, user_id, plans, utcnow(), float(cfg["expiryDays"]), settings.h3_resolution)
    _checked[key] = True
    while len(_checked) > _CHECKED_LIMIT:
        _checked.popitem(last=False)
    return [o for o in live if haversine_m(latitude, longitude, o.latitude, o.longitude) <= radius_m]


LURE_REACH_M = 250.0


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
    """A lamp left out: one thing comes to the place the player picked.

    It goes to the nearest real place within reach of that spot (a park, a pub, a
    landmark), quota aside, and the coins are taken only if something comes. It
    used to take the coins first and then top up to quota, which on a full day
    placed nothing at all.
    """
    cfg = load_config()
    spacing = float(cfg["minSpacingMeters"])
    live = await live_objects(db, user_id, latitude, longitude, LURE_REACH_M + spacing)
    candidates = [
        d
        for d in await discoveries_nearby(db, latitude, longitude, LURE_REACH_M, limit=40)
        if not is_sensitive(d.name, d.tags)
        and all(haversine_m(d.latitude, d.longitude, o.latitude, o.longitude) >= spacing for o in live)
    ]
    if not candidates:
        raise Conflict(
            "Nothing would come to that spot. Try a park, a pub or somewhere with a name.",
            code="NOTHING_TO_LURE",
        )
    cost = int(load_ac_rules()["lure"]["costAC"])
    await economy.debit(db, user_id, cost, "LURE", payload={"latitude": latitude, "longitude": longitude})
    place = candidates[0]
    anchor = Anchor(
        str(place.id),
        place.name,
        place.category,
        place.latitude,
        place.longitude,
        place.h3_index,
        tags=dict(place.tags or {}),
    )
    seed = day_seed(
        user_id, utcnow().date().isoformat(), tile_of(latitude, longitude), f"lure:{utcnow().timestamp():.0f}"
    )
    plans = plan_spawns(
        seed=seed,
        kind="MONSTER",
        indices=[0],
        anchors=[anchor],
        taken_anchor_ids=set(),
        occupied=[],
        cfg=cfg,
        ac_rules=load_ac_rules(),
        frontier=set(),
        known={},
        character_class=character_class,
        activity=normalise(activity),
        centre=None,
    )
    return await _persist(db, user_id, plans, utcnow(), float(cfg["expiryDays"]), settings.h3_resolution)


ROUTE_REACH_M = 150.0


def _far_half(coordinates: list[Any], every_m: float = 200.0) -> list[tuple[float, float]]:
    """Points every 200 m along the route from halfway to nine tenths of the way,
    interpolated, so a route with few vertices is sampled as finely as a dense one."""
    pts = [(float(c[1]), float(c[0])) for c in coordinates if len(c) >= 2]
    if len(pts) < 2:
        return []
    legs = [haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(pts, pts[1:], strict=False)]
    total = sum(legs)
    out: list[tuple[float, float]] = []
    want = 0.5 * total
    walked = 0.0
    for (a, b), leg in zip(zip(pts, pts[1:], strict=False), legs, strict=True):
        while leg > 0 and want <= walked + leg and want <= 0.9 * total:
            f = (want - walked) / leg
            out.append((a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f))
            want += every_m
        walked += leg
    return out


async def place_on_route(
    db: AsyncSession,
    settings: Any,
    user_id: uuid.UUID,
    route_id: uuid.UUID,
    coordinates: list[Any],
    *,
    character_class: str,
    activity: str,
) -> WorldObject | None:
    """A planned route places one thing along its far half, so an outing that goes
    somewhere meets something there (docs/ROADMAP.md, 0.6.1). Once per route, and
    none if something is already waiting on that half (a route planned to a
    creature has its quarry)."""
    cfg = load_config()
    seed = f"route:{route_id}"
    if await _seeds_like(db, user_id, seed):
        return None
    far = _far_half(coordinates)
    if len(far) < 3:
        return None
    centre = far[len(far) // 2]
    radius = max(haversine_m(centre[0], centre[1], lat, lon) for lat, lon in far) + ROUTE_REACH_M

    def beside(lat: float, lon: float) -> bool:
        return any(haversine_m(lat, lon, p[0], p[1]) <= ROUTE_REACH_M for p in far)

    live = await live_objects(db, user_id, centre[0], centre[1], radius)
    if any(o.kind == "MONSTER" and beside(o.latitude, o.longitude) for o in live):
        return None
    spacing = float(cfg["minSpacingMeters"])
    anchors = [
        Anchor(str(d.id), d.name, d.category, d.latitude, d.longitude, d.h3_index, tags=dict(d.tags or {}))
        for d in await discoveries_nearby(db, centre[0], centre[1], radius, limit=400)
        if not is_sensitive(d.name, d.tags)
        and beside(d.latitude, d.longitude)
        and all(haversine_m(d.latitude, d.longitude, o.latitude, o.longitude) >= spacing for o in live)
    ]
    if not anchors:
        return None
    plans = plan_spawns(
        seed=seed,
        kind="MONSTER",
        indices=[0],
        anchors=anchors,
        taken_anchor_ids={str(o.anchor_discovery_id) for o in live if o.anchor_discovery_id},
        occupied=[(o.latitude, o.longitude) for o in live],
        cfg=cfg,
        ac_rules=load_ac_rules(),
        frontier=set(),
        known={},
        character_class=character_class,
        activity=normalise(activity),
        centre=None,
    )
    placed = await _persist(db, user_id, plans, utcnow(), float(cfg["expiryDays"]), settings.h3_resolution)
    if placed:
        log.info("world_object_on_route", route_id=str(route_id), object_id=str(placed[0].id))
    return placed[0] if placed else None


def elder_seed(step_slug: str) -> str:
    """The seed of a story step's elder. Seeds are unique per user, so the user
    is not in it; with it, the longest step slug ran past the 96-character column."""
    return f"story:{step_slug}"


async def place_elder(
    db: AsyncSession,
    settings: Any,
    user_id: uuid.UUID,
    latitude: float,
    longitude: float,
    *,
    step_slug: str,
    spec: dict[str, Any],
    character_class: str,
    activity: str,
) -> WorldObject | None:
    """A named elder bound to a story step, the finale of a chapter: an old one
    of the given tier at a real place beyond the near ring, whose wants include
    the rune with the given road form without needing it. Once per step; the one
    already standing is used again. It stays while the step is open
    (`expire_stale`)."""
    from app.core.activity import DISTANCE_SCALE
    from app.world_objects.spawner import species_road_form

    seed = elder_seed(step_slug)
    standing = await db.scalar(
        select(WorldObject).where(
            WorldObject.user_id == user_id,
            WorldObject.status == "SPAWNED",
            WorldObject.seed.like(f"{seed}:%"),
        )
    )
    if standing is not None:
        return standing
    cfg = load_config()
    form = spec.get("roadForm")
    species = [
        m
        for m in cfg["monsters"]
        if "RUNE" in (m.get("wants") or []) and (form is None or species_road_form(m) == form)
    ]
    if not species:
        return None
    scale = DISTANCE_SCALE.get(normalise(activity), 1.0)
    lo, hi = (float(x) * 1000 * scale for x in spec.get("distanceKm", [1.5, 4]))
    live = await live_objects(db, user_id, latitude, longitude, hi + float(cfg["minSpacingMeters"]))
    anchors = [
        Anchor(str(d.id), d.name, d.category, d.latitude, d.longitude, d.h3_index, tags=dict(d.tags or {}))
        for d in await discoveries_nearby(db, latitude, longitude, hi, limit=600)
        if not is_sensitive(d.name, d.tags) and haversine_m(latitude, longitude, d.latitude, d.longitude) >= lo
    ]
    if not anchors:
        return None
    tier = int(spec.get("tier", 3))
    attempts = len(await _seeds_like(db, user_id, seed))
    plans = plan_spawns(
        seed=f"{seed}:{attempts}" if attempts else seed,
        kind="MONSTER",
        indices=[0],
        anchors=anchors,
        taken_anchor_ids={str(o.anchor_discovery_id) for o in live if o.anchor_discovery_id},
        occupied=[(o.latitude, o.longitude) for o in live],
        cfg={**cfg, "monsters": species, "tierWeights": [1 if t == tier else 0 for t in (1, 2, 3)]},
        ac_rules=load_ac_rules(),
        frontier=set(),
        known={},
        character_class=character_class,
        activity=normalise(activity),
        centre=None,
    )
    for plan in plans:
        plan.payload["storyStep"] = step_slug
    placed = await _persist(db, user_id, plans, utcnow(), float(spec.get("lifeDays", 21)), settings.h3_resolution)
    if placed:
        log.info("story_elder_placed", step=step_slug, object_id=str(placed[0].id), name=placed[0].payload.get("name"))
    return placed[0] if placed else None


# --- effort is damage -----------------------------------------------------------


def combat_config() -> dict[str, Any]:
    return load_config()["combat"]


def wounds_of(obj: WorldObject) -> dict[str, dict[str, Any]]:
    """What each ride has taken off it, by ride id."""
    return dict(((obj.payload or {}).get("wounds") or {}).get("rides") or {})


def foe_of(obj: WorldObject, *, excluding_ride: str | None = None, day: str | None = None) -> fight.Foe:
    """The thing as the fight sees it. Rows from before species had blocks are
    read from the catalogue by name."""
    payload = obj.payload or {}
    block = payload.get("species") or {}
    species = lore.species_by_id().get(lore.species_of(payload) or "") or {}
    wants = tuple(block.get("wants") or species.get("wants") or ())
    minds = tuple(block.get("minds") or species.get("minds") or ())
    form = block.get("roadForm")
    if form is None and species.get("rune"):
        form = (lore.runes_by_id().get(species["rune"]) or {}).get("roadForm")
    cfg = combat_config()
    hold_max = float(payload.get("holdMax") or cfg["holdByTier"].get(str(obj.tier), obj.tier * 100))
    rides = {k: v for k, v in wounds_of(obj).items() if k != excluding_ride}
    taken = sum(float(w.get("taken", 0)) for w in rides.values())
    today = [w for w in rides.values() if day and w.get("day") == day]
    return fight.Foe(
        latitude=obj.latitude,
        longitude=obj.longitude,
        hold_max=hold_max,
        hold_before=max(0.0, hold_max - taken),
        wants=wants,
        minds=minds,
        road_form=form,
        rune_today=any(w.get("runeLanded") for w in today),
        word_today=any(w.get("wordLanded") for w in today),
    )


async def window_objects(
    db: AsyncSession,
    user_id: uuid.UUID,
    latitude: float,
    longitude: float,
    radius_m: float,
    started: datetime,
    ended: datetime,
) -> list[WorldObject]:
    """What was out there while the ride was: placed before it ended and not gone
    before it began, whatever its status now. A late upload is judged against the
    world it rode through, not the one there now."""
    stmt = select(WorldObject).where(
        WorldObject.user_id == user_id,
        WorldObject.status.in_(["SPAWNED", "EXPIRED"]),
        WorldObject.spawned_at <= ended,
        WorldObject.expires_at >= started,
    )
    rows = (await db.execute(bbox_filter(stmt, WorldObject, latitude, longitude, radius_m))).scalars().all()
    return [r for r in rows if haversine_m(latitude, longitude, r.latitude, r.longitude) <= radius_m]


def _fight_points(points: list[CleanPoint], cfg: dict[str, Any]) -> list[fight.FightPoint]:
    limit = float(cfg["maxAccuracyMeters"])
    return [
        fight.FightPoint(p.latitude, p.longitude, p.altitude, ok=p.accuracy is None or p.accuracy <= limit)
        for p in points
    ]


def _word_indices(points: list[CleanPoint], events: list[dict[str, Any]], cfg: dict[str, Any]) -> list[int]:
    """Where on the trace a note of a few words was written: the fix nearest the
    moment it was written, so the server, not the phone, says where that was."""
    out = []
    for event in events:
        note = str(event.get("note") or "").strip()
        if len(note) < int(cfg["wordMinChars"]):
            continue
        when = event.get("occurredAt")
        try:
            moment = datetime.fromisoformat(str(when).replace("Z", "+00:00")) if when else None
        except ValueError:
            moment = None
        if moment is None:
            continue
        nearest = min(range(len(points)), key=lambda i: abs((points[i].timestamp - moment).total_seconds()))
        out.append(nearest)
    return out


def _made_good_m(points: list[CleanPoint]) -> float:
    return sum(
        haversine_m(a.latitude, a.longitude, b.latitude, b.longitude) for a, b in zip(points, points[1:], strict=False)
    )


async def _overlaps_another(db: AsyncSession, ride: Any) -> bool:
    """A second recording of the same time loosens nothing: one outing, one count."""
    from app.rides.models import Ride

    if ride.ended_at is None:
        return False
    other = await db.scalar(
        select(Ride.id).where(
            Ride.user_id == ride.user_id,
            Ride.id != ride.id,
            Ride.status == "PROCESSED",
            Ride.started_at < ride.ended_at,
            Ride.ended_at > ride.started_at,
        )
    )
    return other is not None


def _wound(
    obj: WorldObject, ride_id: str, day: str, report: fight.FightReport, ended: datetime, *, bounty_keeps_days: int = 0
) -> None:
    """Writes what this ride took off it. Keyed by ride, so a rerun replaces rather
    than adds, and reassigned, because the JSON column does not see edits in place."""
    cfg = combat_config()
    rides = wounds_of(obj)
    rides[ride_id] = {
        "day": day,
        "taken": round(report.taken, 2),
        "damage": {k: round(v, 2) for k, v in report.damage.items()},
        "runeLanded": report.rune_landed,
        "wordLanded": report.word_landed,
    }
    obj.payload = {**(obj.payload or {}), "wounds": {"rides": rides}}
    # A loosened thing stays a little longer, out of stubbornness: two days from
    # this outing, never more than a week from when it first appeared.
    stays = ended + timedelta(days=float(cfg["loosenedStaysDays"]))
    cap = obj.spawned_at + timedelta(days=float(cfg["maxLifeDays"]))
    obj.expires_at = max(obj.expires_at, min(stays, cap))
    if obj.bounty and bounty_keeps_days:
        # Algiz: a loosened bounty keeps its double purse, and stays a little longer.
        obj.expires_at = min(obj.expires_at + timedelta(days=bounty_keeps_days), cap)
    elif obj.bounty:
        # A loosened bounty stays on as an ordinary thing at the ordinary purse.
        obj.bounty = False
        obj.reward_ac = int(load_ac_rules()["monster"][str(obj.tier)])


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
    effort: bool = False,
    new_cell_indices: list[int] | None = None,
    sheet: Any = None,
) -> ClaimOutcome:
    """Everything the trace passed or beat. Chests and pieces are passed; monsters are fought.

    With `effort` (flag effort_combat) a monster is fought by effort over the outing
    (fight.py), and is loosened or seen off; without it, the old pass/fail check.
    """
    outcome = ClaimOutcome(effort=effort)
    if len(points) < 2:
        return outcome
    cfg = load_config()
    lats = [p.latitude for p in points]
    lons = [p.longitude for p in points]
    centre_lat, centre_lon = (min(lats) + max(lats)) / 2, (min(lons) + max(lons)) / 2
    reach = max(haversine_m(centre_lat, centre_lon, lat, lon) for lat, lon in zip(lats, lons, strict=True)) + 1200
    if effort:
        started = getattr(ride, "started_at", None) or ended
        live = await window_objects(db, ride.user_id, centre_lat, centre_lon, reach, started, ended)
        live = [o for o in live if not (o.kind != "MONSTER" and o.status != "SPAWNED")]
    else:
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
        if effort:
            # Fought below, all together, once the cheap work is done.
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
    if effort:
        await _fight_by_effort(
            db,
            ride,
            outcome,
            [o for o in live if o.kind == "MONSTER"],
            points,
            coords,
            encounter_events,
            new_cell_indices or [],
            sheet,
            ended,
        )
    await db.flush()
    outcome.owned = await pieces_owned(db, ride.user_id)
    outcome.sets_completed = newly_completed(held, outcome.owned)
    return outcome


async def _fight_by_effort(
    db: AsyncSession,
    ride: Any,
    outcome: ClaimOutcome,
    monsters: list[WorldObject],
    points: list[CleanPoint],
    coords: list[tuple[float, float]],
    events: list[dict[str, Any]],
    new_cell_indices: list[int],
    sheet: Any,
    ended: datetime,
) -> None:
    from app.characters.sheet import CharacterSheet

    base_cfg = combat_config()
    sheet = sheet or CharacterSheet.neutral()
    # An outing too short to count, or a second recording of the same time, loosens nothing.
    if _made_good_m(points) < float(base_cfg["minOutingMeters"]) or await _overlaps_another(db, ride):
        outcome.missed.extend((m, "NOT_NEAR") for m in monsters if m.status == "SPAWNED")
        return
    ride_id = str(getattr(ride, "id", ""))
    ride_uuid = getattr(ride, "id", None)
    user_id = getattr(ride, "user_id", None)
    day = ended.date().isoformat()
    activity = normalise(getattr(ride, "activity", "RIDE"))
    made_good = _made_good_m(points)
    min_len = float(base_cfg.get("runeMinLengthMeters", 300))
    max_len = float(base_cfg.get("runeMaxLengthMeters", 4000))

    # Waking (0.7.0): an inscribed rune's road form cut on an outing planned to cut it
    # (a rune ride) wakes it. Once per outing, it counts a rank deeper and lands on
    # everything in reach. A shape an ordinary outing happens to make wakes nothing:
    # street grids make squares, and the replay found three ordinary outings in five
    # would have woken one by chance.
    woken: list[tuple[float, float, int]] = []
    planned = await _planned_rune(db, ride)
    for rune_id in [r for r in sheet.inscribed if r == planned]:
        form = runes_catalog.road_form(rune_id)
        if form not in runes_catalog.CUT_FORMS:
            continue
        found = claims.match_anywhere(
            coords, form, threshold=sheet.rune_threshold, min_length_m=min_len, max_length_m=max_len
        )
        if found is None:
            continue
        lat, lon, index = found
        sheet = sheet.woken(rune_id)
        woken.append((lat, lon, index))
        outcome.woken.append(rune_id)
        if user_id is not None:
            await inventory.record_cut(
                db, user_id, ride_id=ride_uuid, rune_id=rune_id, latitude=lat, longitude=lon, source="WAKING", woke=True,
                at=points[index].timestamp if index < len(points) else ended,
            )  # fmt: skip

    first_today = await _outings_today_before(db, ride) + 1
    cfg = sheet.fight_cfg(base_cfg, first_outings_today=first_today)
    fight_points = _fight_points(points, cfg)
    words = _word_indices(points, events, cfg)
    # Wunjo: a stop long enough at a café, a pub or a green place is the word.
    if sheet.rules.get("STOP_IS_WORD_S"):
        words += await _stops_as_words(db, points, float(sheet.rules["STOP_IS_WORD_S"]))
    old_places = await _old_place_anchors(db, monsters)
    # The Ground Six add a want to the first few of a family met on the outing.
    extra_wants = _ground_wants(sheet, monsters, fight_points, cfg, activity)
    for obj in monsters:
        try:
            foe = foe_of(obj, excluding_ride=ride_id, day=day)
            if extra_wants.get(obj.id):
                foe = fight.Foe(**{**foe.__dict__, "wants": tuple(sorted(set(foe.wants) | extra_wants[obj.id]))})
            hit = None
            if foe.road_form and not foe.rune_today:
                match = claims.match_rune(
                    coords,
                    (obj.latitude, obj.longitude),
                    threshold=sheet.rune_threshold,
                    search_radius_m=sheet.rune_reach_m,
                    min_length_m=min_len,
                    max_length_m=max_len,
                )
                if match is not None:
                    hit = fight.RuneHit(match.shape, match.end)
                    if match.shape == foe.road_form and user_id is not None:
                        cut_rune = runes_catalog.rune_for_form(match.shape)
                        if cut_rune:
                            at = coords[min(match.end, len(coords) - 1)]
                            await inventory.record_cut(
                                db, user_id, ride_id=ride_uuid, rune_id=cut_rune, latitude=at[0], longitude=at[1],
                                source="FIGHT", place_name=obj.payload.get("anchorName"),
                            )  # fmt: skip
            if hit is None or hit.shape != foe.road_form:
                near = [w for w in woken if haversine_m(w[0], w[1], obj.latitude, obj.longitude) <= sheet.rune_reach_m]
                if near:
                    hit = fight.RuneHit(fight.WOKEN, near[0][2])
            # The build against this one: elders and bounties, an old place, a long outing.
            pct = sheet.pct_against(
                elder=obj.tier >= 2 or bool(obj.bounty),
                old_place=obj.anchor_discovery_id in old_places,
                made_good_m=made_good,
                foot=activity in ("RUN", "WALK"),
            )
            report = fight.resolve(
                fight_points,
                foe,
                activity=activity,
                damage_pct=pct,
                cfg=cfg,
                new_cell_indices=new_cell_indices,
                rune_hit=hit,
                word_indices=words,
            )
        except Exception as exc:  # noqa: BLE001 - one bad fight is a miss, never a lost outing
            log.error("fight_failed", ride_id=ride_id, object_id=str(obj.id), error=str(exc)[:200])
            if "FIGHT_ERROR" not in outcome.flags:
                outcome.flags.append("FIGHT_ERROR")
            continue
        if report.outcome == "NOT_NEAR":
            if obj.status == "SPAWNED":
                outcome.missed.append((obj, "NOT_NEAR"))
            continue
        share = min(1.0, report.taken / max(1.0, report.hold_max))
        if share > 0:
            outcome.blows.append((obj.tier, bool(obj.bounty), share))
        outcome.fights.append(
            {
                "id": str(obj.id),
                "name": obj.payload.get("name"),
                "speciesId": lore.species_of(obj.payload),
                "tier": obj.tier,
                "bounty": bool(obj.bounty),
                "latitude": obj.latitude,
                "longitude": obj.longitude,
                **report.to_dict(),
                "expiresAt": obj.expires_at.isoformat(),
            }
        )
        keeps = int(sheet.rules.get("BOUNTY_KEEPS_PURSE", 0))
        if report.outcome == "SEEN_OFF":
            _wound(obj, ride_id, day, report, ended)
            if obj.status == "SPAWNED":
                _claim(obj, ride, ended, {"method": "EFFORT", "finisher": report.finisher, **report.to_dict()})
                outcome.claimed.append(obj)
        elif report.taken >= 1:
            _wound(obj, ride_id, day, report, ended, bounty_keeps_days=keeps)
            outcome.fights[-1]["expiresAt"] = obj.expires_at.isoformat()
            if obj.status == "SPAWNED":
                outcome.missed.append((obj, "LOOSENED"))
        elif obj.status == "SPAWNED":
            outcome.missed.append((obj, "UNTOUCHED"))


async def _planned_rune(db: AsyncSession, ride: Any) -> str | None:
    """The rune a ride was planned to cut, if it was a rune ride."""
    from app.routing.models import Route

    route_id = getattr(ride, "route_id", None)
    if route_id is None:
        return None
    route = await db.get(Route, route_id)
    return str((route.request or {}).get("rune") or "") or None if route is not None else None


GROUND_RULES = {
    # rule id: (family, kind it comes to want, only on a bike)
    "WANTS_ROAD_AT_WATER": ("WATER", "ROAD", False),
    "WANTS_GROUND_AT_GREEN": ("GREEN", "GROUND", False),
    "WANTS_WORD_AT_STONE": ("STONE", "WORD", False),
    "WANTS_ROAD_ON_STREET_BY_BIKE": ("STREET", "ROAD", True),
}


def _ground_wants(
    sheet: Any, monsters: list[WorldObject], points: list[fight.FightPoint], cfg: dict[str, Any], activity: str
) -> dict[uuid.UUID, set[str]]:
    """What the inscribed Ground Six add to the wants of the first few things of
    their family the outing met, in the order it met them."""
    rules = {r: v for r, v in sheet.rules.items() if r in GROUND_RULES}
    if not rules:
        return {}
    engage = float(cfg["engageMeters"])

    def contact(obj: WorldObject) -> int | None:
        return next(
            (
                i
                for i, p in enumerate(points)
                if p.ok and haversine_m(p.latitude, p.longitude, obj.latitude, obj.longitude) <= engage
            ),
            None,
        )

    met = sorted(((c, m) for m in monsters if (c := contact(m)) is not None), key=lambda x: x[0])
    out: dict[uuid.UUID, set[str]] = {}
    for rule, count in rules.items():
        family, kind, by_bike = GROUND_RULES[rule]
        if by_bike and activity != "RIDE":
            continue
        given = 0
        for _, obj in met:
            species = lore.species_by_id().get(lore.species_of(obj.payload) or "") or {}
            if str(species.get("family") or "").upper() != family:
                continue
            if given >= int(count):
                break
            out.setdefault(obj.id, set()).add(kind)
            given += 1
    return out


async def _outings_today_before(db: AsyncSession, ride: Any) -> int:
    """Processed outings started earlier the same day (Dagaz counts the first few)."""
    from sqlalchemy import func

    from app.rides.models import Ride

    started = getattr(ride, "started_at", None)
    if started is None:
        return 0
    day_start = started.replace(hour=0, minute=0, second=0, microsecond=0)
    return int(
        await db.scalar(
            select(func.count(Ride.id)).where(
                Ride.user_id == ride.user_id,
                Ride.id != ride.id,
                Ride.status == "PROCESSED",
                Ride.started_at >= day_start,
                Ride.started_at < started,
            )
        )
        or 0
    )


STOP_RADIUS_M = 40.0
STOP_PLACE_M = 80.0
STOP_CATEGORIES = ("CAFE", "PUB", "NATURE", "FOOD")


async def _stops_as_words(db: AsyncSession, points: list[CleanPoint], seconds: float) -> list[int]:
    """Where the outing stopped long enough at a café, a pub or a green place: the
    fix it stopped at, once per place (Wunjo). A stop is staying within 40 m."""
    out: list[int] = []
    used: set[uuid.UUID] = set()
    i = 0
    while i < len(points):
        j = i
        while (
            j + 1 < len(points)
            and haversine_m(points[i].latitude, points[i].longitude, points[j + 1].latitude, points[j + 1].longitude)
            <= STOP_RADIUS_M
        ):
            j += 1
        if (points[j].timestamp - points[i].timestamp).total_seconds() >= seconds:
            here = points[i]
            places = [
                d
                for d in await discoveries_nearby(db, here.latitude, here.longitude, STOP_PLACE_M, limit=10)
                if d.category in STOP_CATEGORIES and not is_sensitive(d.name, d.tags) and d.id not in used
            ]
            if places:
                used.add(places[0].id)
                out.append(i)
            i = j + 1
        else:
            i += 1
    return out


OLD_PLACE_CATEGORIES = ("HISTORICAL", "CULTURAL")


async def _old_place_anchors(db: AsyncSession, monsters: list[WorldObject]) -> set[uuid.UUID]:
    """Which of these things stand at an old or cultural place (the Historian's
    knack). Sensitive places never anchor anything, so none is among them."""
    from app.discoveries.models import Discovery

    ids = {m.anchor_discovery_id for m in monsters if m.anchor_discovery_id}
    if not ids:
        return set()
    rows = await db.execute(
        select(Discovery.id).where(Discovery.id.in_(ids), Discovery.category.in_(OLD_PLACE_CATEGORIES))
    )
    return set(rows.scalars())


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
    coin_pct: dict[str, float] | None = None,
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
    # A knack that makes boxes pay more (Rumour) pays on a box opened by hand too.
    paid = int(round(obj.reward_ac * (1 + float((coin_pct or {}).get(obj.kind, 0.0)))))
    if paid > 0:
        await economy.credit(
            db,
            user_id,
            paid,
            "BOUNTY" if obj.bounty else TAP_KINDS[obj.kind],
            object_id=obj.id,
            payload={"objectId": str(obj.id), "name": obj.payload.get("name"), "method": "TAP"},
        )
    await db.flush()
    log.info("world_object_claimed", user=str(user_id), kind=obj.kind, method="TAP", meters=round(distance, 1))
    return obj, paid + (finished["bonusAC"] if finished else 0), finished


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
