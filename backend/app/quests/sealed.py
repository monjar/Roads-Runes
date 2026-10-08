"""The sealed quest (0.7.3): pick a time, the board picks the way, the goal opens halfway.

One objective, `hidden` like a puzzle's (quests/service.objective_out drops its
place until it is done), at somewhere about half the asked time away at the
activity's usual speed: a hidden place or a creature when there is one, a place
already found when not, a tile on the map at the last. The route goes there and
back, so the journey lasts about the minutes asked. The objective's `extra`
carries `revealAtFraction` and the `goal` itself (name, kind, where), which the
phone keeps back until the route is that far along: the hiding is the phone's,
and the route already leads there.

No new tables: a quest instance (`templateId` SEALED) and a route, through the
existing services. One at a time: a new one retires one not yet started.
"""

from __future__ import annotations

import random
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.characters.models import Character
from app.characters.service import get_rider_profile
from app.core.activity import ASSUMED_SPEED_KMH, normalise, verb
from app.core.config import Settings
from app.core.geo import destination_point, haversine_m
from app.core.llm import LLMClient
from app.core.schemas import Coordinate
from app.core.security import utcnow
from app.discoveries import osm_import
from app.discoveries.models import Discovery
from app.discoveries.sensitivity import is_sensitive
from app.discoveries.service import nearby as discoveries_nearby
from app.discoveries.service import user_found
from app.economy.rules import quest_ac
from app.exploration.cells import cell_center, cell_for
from app.lore.catalog import articled
from app.quests.generator import GeneratedObjective, GeneratedQuest
from app.quests.models import QuestInstance
from app.quests.service import _persist
from app.quests.templates import ANY_CLASS
from app.routing.engine import RoutingEngine
from app.routing.models import Route
from app.routing.schemas import RouteGenerateRequest
from app.users.models import User
from app.world_objects import service as world_objects
from app.world_objects import variants
from app.world_objects.models import WorldObject

TEMPLATE_ID = "SEALED"
QUEST_TYPE = "SEALED"
MINUTES = (20, 40, 90)
REVEAL_AT_FRACTION = 0.5
DESCRIPTION = "The board picked the way. Your goal opens halfway."
OBJECTIVE_TITLE = "Reach the goal"
# Roads are about this much longer than the crow's line between two points.
DETOUR = 1.3
# How far either side of the wanted distance a goal may be, as a share of it.
RING = (0.6, 1.4)
# A sealed quest is for now: it is gone in a day if it is not ridden.
TTL = timedelta(days=1)
# Placed things and places are looked for this many times round the circle.
BEARINGS = 8
SPAWN_LOOK_M = 6000.0
PLACE_RADIUS_M = 90.0
CREATURE_RADIUS_M = 150.0
TILE_RADIUS_M = 250.0


def title_for(minutes: int) -> str:
    return f"Sealed quest ({minutes} min)"


def difficulty_for(minutes: int) -> str:
    """Paid like an easy quest, or a moderate one for the long one."""
    return "EASY" if minutes <= 40 else "MODERATE"


def one_way_km(minutes: int, activity: str) -> float:
    """Half the time asked, at the activity's usual speed: the way there."""
    return ASSUMED_SPEED_KMH.get(normalise(activity), 15.0) * minutes / 60 / 2


@dataclass
class Goal:
    kind: str  # PLACE (hidden or found), CREATURE or TILE
    name: str
    latitude: float
    longitude: float
    distance_m: float
    hidden_place: bool = False
    category: str | None = None
    discovery_id: str | None = None
    object_id: str | None = None
    icon: str | None = None
    cell: str | None = None

    def title(self, activity: str) -> str:
        """What the goal is, once it opens: "Ride to Stave Hill", "Run to the Fen Troll"."""
        if self.kind == "CREATURE":
            return articled(f"{verb(activity)} to the {self.name}", self.name)
        return f"{verb(activity)} to {self.name}"

    def to_dict(self, activity: str) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "name": self.name,
            "title": self.title(activity),
            "latitude": self.latitude,
            "longitude": self.longitude,
            "category": self.category,
            "discoveryId": self.discovery_id,
            "objectId": self.object_id,
            "icon": self.icon,
        }


async def _places_round(
    db: AsyncSession, latitude: float, longitude: float, target_m: float, rng: random.Random
) -> list[Discovery]:
    """Places about `target_m` away, looked for at points round the circle: a plain
    radius query is nearest-first and, in a city, never gets that far out."""
    start = rng.uniform(0, 360)
    # Half the distance out, so eight circles cover the ring between them.
    reach = max(400.0, target_m * 0.5)
    seen: dict[uuid.UUID, Discovery] = {}
    for i in range(BEARINGS):
        lat, lon = destination_point(latitude, longitude, (start + i * 360 / BEARINGS) % 360, target_m)
        for place in await discoveries_nearby(db, lat, lon, reach, limit=40):
            seen.setdefault(place.id, place)
    return list(seen.values())


def _in_ring(distance_m: float, target_m: float) -> bool:
    return RING[0] * target_m <= distance_m <= RING[1] * target_m


async def pick_goal(
    db: AsyncSession,
    settings: Settings,
    user: User,
    character: Character,
    latitude: float,
    longitude: float,
    target_m: float,
    activity: str,
    rng: random.Random,
    exclude: set[str] | None = None,
) -> Goal:
    """Somewhere about `target_m` from here, as the crow flies."""
    exclude = exclude or set()
    creatures: list[Goal] = []
    # The world placed round the player as the board places it (the same radius, so
    # the day's first look is the usual one), then read out as far as the ring goes.
    await world_objects.ensure_spawned(
        db,
        settings,
        user.id,
        latitude,
        longitude,
        SPAWN_LOOK_M,
        character_class=character.character_class,
        activity=activity,
    )
    live = await world_objects.live_objects(db, user.id, latitude, longitude, target_m * RING[1])
    # Still there by the time the journey is.
    later = utcnow() + timedelta(hours=3)
    for obj in live:
        if obj.kind != "MONSTER" or str(obj.id) in exclude or obj.expires_at < later:
            continue
        d = haversine_m(latitude, longitude, obj.latitude, obj.longitude)
        if _in_ring(d, target_m):
            creatures.append(_creature_goal(obj, d))
    places = [
        p
        for p in await _places_round(db, latitude, longitude, target_m, rng)
        if str(p.id) not in exclude and not is_sensitive(p.name, p.tags) and (p.name or "").strip()
    ]
    found = await user_found(db, user.id, [p.id for p in places])
    hidden: list[Goal] = []
    known: list[Goal] = []
    for p in places:
        d = haversine_m(latitude, longitude, p.latitude, p.longitude)
        if not _in_ring(d, target_m):
            continue
        goal = Goal(
            kind="PLACE",
            name=p.name.strip(),
            latitude=p.latitude,
            longitude=p.longitude,
            distance_m=d,
            hidden_place=p.id not in found,
            category=p.category,
            discovery_id=str(p.id),
        )
        (known if p.id in found else hidden).append(goal)
    for pool in (hidden + creatures, known):
        if pool:
            pool.sort(key=lambda g: (abs(g.distance_m - target_m), g.name))
            return rng.choice(pool[:5])
    return _tile_goal(latitude, longitude, target_m, settings.h3_resolution, rng)


def _creature_goal(obj: WorldObject, distance_m: float) -> Goal:
    from app.between.pledges import creature_icon

    payload = obj.payload or {}
    return Goal(
        kind="CREATURE",
        name=variants.display_name(payload) or str(payload.get("name") or "Creature"),
        latitude=obj.latitude,
        longitude=obj.longitude,
        distance_m=distance_m,
        object_id=str(obj.id),
        icon=creature_icon(payload),
    )


def _tile_goal(latitude: float, longitude: float, target_m: float, resolution: int, rng: random.Random) -> Goal:
    lat, lon = destination_point(latitude, longitude, rng.uniform(0, 360), target_m)
    cell = cell_for(lat, lon, resolution)
    lat, lon = cell_center(cell)
    return Goal(
        kind="TILE",
        name="a tile on the map",
        latitude=lat,
        longitude=lon,
        distance_m=haversine_m(latitude, longitude, lat, lon),
        cell=cell,
    )


def objective_for(goal: Goal, activity: str) -> GeneratedObjective:
    extra: dict[str, Any] = {
        "sealed": True,
        "hidden": True,
        "revealAtFraction": REVEAL_AT_FRACTION,
        "goal": goal.to_dict(activity),
    }
    o = GeneratedObjective(
        objective_type="VISIT_LOCATION", title=OBJECTIVE_TITLE, required=True, order=1,
        latitude=goal.latitude, longitude=goal.longitude,
    )  # fmt: skip
    if goal.kind == "PLACE":
        o.objective_type = "VISIT_POI"
        o.radius_meters = PLACE_RADIUS_M
        o.discovery_id = goal.discovery_id
        extra.update({"poiName": goal.name, "category": goal.category})
    elif goal.kind == "CREATURE":
        o.radius_meters = CREATURE_RADIUS_M
        # Named once it is done, as a place is; until then only `goal` says.
        extra["objectName"] = goal.name
    else:
        o.radius_meters = TILE_RADIUS_M
        o.target_cells = [goal.cell] if goal.cell else None
    o.extra = extra
    return o


def generated_quest(goal: Goal, minutes: int, activity: str, latitude: float, longitude: float) -> GeneratedQuest:
    from app.progression.engine import load_xp_rules

    difficulty = difficulty_for(minutes)
    base_xp = int(load_xp_rules()["questBase"][difficulty])
    return GeneratedQuest(
        template_id=TEMPLATE_ID,
        quest_type=QUEST_TYPE,
        character_class=ANY_CLASS,
        title=title_for(minutes),
        description=DESCRIPTION,
        difficulty=difficulty,
        recommended_distance_km=round(one_way_km(minutes, activity) * 2, 1),
        estimated_duration_minutes=minutes,
        base_xp=base_xp,
        objectives=[objective_for(goal, activity)],
        # The quest's own extra (QuestOut.extra, service.quest_extra) is kept here.
        narrative={
            "hook": DESCRIPTION,
            "completion": None,
            "source": "sealed",
            "sealed": {"minutes": minutes, "revealAtFraction": REVEAL_AT_FRACTION},
        },
        seed=f"{TEMPLATE_ID}:{minutes}",
        latitude=latitude,
        longitude=longitude,
        rewards={"xp": base_xp, "ac": quest_ac(difficulty), "items": [], "titles": []},
        variables={"minutes": minutes},
        activity=activity,
    )


async def retire_unstarted(db: AsyncSession, user: User) -> int:
    """One sealed quest at a time: a new one replaces any not yet started."""
    rows = (
        await db.execute(
            select(QuestInstance).where(
                QuestInstance.user_id == user.id,
                QuestInstance.template_id == TEMPLATE_ID,
                QuestInstance.status.in_(["AVAILABLE", "ACCEPTED"]),
            )
        )
    ).scalars()
    retired = 0
    for quest in rows:
        quest.status = "EXPIRED"
        retired += 1
    return retired


async def _route_to(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    origin: Coordinate,
    goal: Goal,
    total_km: float,
    activity: str,
) -> Route:
    """There and back through the goal: one route, not a choice of three."""
    from app.routing import service as routing

    payload = RouteGenerateRequest(
        origin=origin,
        waypoints=[Coordinate(latitude=goal.latitude, longitude=goal.longitude)],
        loop=True,
        distanceTargetKm=min(400.0, max(1.0, total_km)),
        activity=activity,  # type: ignore[arg-type]
    )
    results, _ = await routing.generate(db, settings, engine, llm, user, payload, max_variants=1)
    return results[0][0]


async def create(
    db: AsyncSession,
    settings: Settings,
    engine: RoutingEngine,
    llm: LLMClient,
    user: User,
    character: Character,
    *,
    minutes: int,
    latitude: float,
    longitude: float,
    activity: str | None,
    now: datetime | None = None,
) -> QuestInstance:
    """A sealed quest from here, accepted and with its route fixed."""
    from app.routing.service import settle_quest_distance

    now = now or utcnow()
    activity = normalise(activity or (await get_rider_profile(db, user.id)).default_activity)
    await retire_unstarted(db, user)
    await osm_import.ensure_pois(settings, latitude, longitude)
    rng = random.Random(f"{user.id}:{now.isoformat()}")
    origin = Coordinate(latitude=latitude, longitude=longitude)
    total_km = one_way_km(minutes, activity) * 2
    target_m = total_km / 2 * 1000 / DETOUR
    goal = await pick_goal(db, settings, user, character, latitude, longitude, target_m, activity, rng)
    route = await _route_to(db, settings, engine, llm, user, origin, goal, total_km, activity)
    # Roads are not all equally winding: a way far off the time asked is tried once
    # more, with somewhere nearer or further by as much as it missed.
    ratio = route.distance_meters / (total_km * 1000) if total_km else 1.0
    if not 0.7 <= ratio <= 1.4 and route.distance_meters > 0:
        tried = {g for g in (goal.discovery_id, goal.object_id) if g}
        again = await pick_goal(
            db, settings, user, character, latitude, longitude, target_m / ratio, activity, rng, exclude=tried
        )
        second = await _route_to(db, settings, engine, llm, user, origin, again, total_km, activity)
        if abs(second.distance_meters / (total_km * 1000) - 1) < abs(ratio - 1):
            goal, route = again, second
    quest = _persist(user, generated_quest(goal, minutes, activity, latitude, longitude), now)
    quest.status = "ACCEPTED"
    quest.accepted_at = now
    quest.expires_at = now + TTL
    db.add(quest)
    await db.flush()
    route.quest_id = quest.id
    quest.suggested_route_id = route.id
    settle_quest_distance(quest, route)
    await db.flush()
    await db.refresh(quest)
    return quest
